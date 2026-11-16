#include <lean/lean.h>
#include <libpq-fe.h>
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

/* Exported by libleanrt (C linkage) but not declared in lean.h of this toolchain. */
void lean_initialize_thread(void);
void lean_finalize_thread(void);

/* Exported from lean/Conn.lean; each takes ownership of its object arguments
   and returns a fresh (State × Action) pair. */
extern lean_object *ekk_conn_open(uint8_t unit);
extern lean_object *ekk_conn_on_recv(uint64_t now, lean_object *state, lean_object *data);
extern lean_object *ekk_conn_on_sent(uint64_t now, lean_object *state, size_t n);
extern lean_object *ekk_conn_on_fail(lean_object *state);
extern lean_object *ekk_conn_on_refused(lean_object *state);
extern lean_object *ekk_conn_on_answer(uint64_t now, lean_object *state, lean_object *result);

void ekk_thread_init(void) { lean_initialize_thread(); }
void ekk_thread_fini(void) { lean_finalize_thread(); }

/* Conn.Action decoded for the loop. Constructor order in Conn.lean:
   recv (room) = 0, send (data, off) = 1, close = 2, none = 3, query (q) = 4. */
typedef struct {
    uint8_t kind;  /* 0 recv, 1 send, 2 close, 3 none, 4 query */
    size_t room;   /* recv: most bytes to receive */
    size_t len;    /* send: bytes copied into out */
    lean_object *query; /* query: the Server.Query, owned by the receiver */
} ekk_action;

/* Splits the (State × Action) pair: stores the new state in *state and decodes
   the action; a send copies data[off..] into out, at most cap bytes, and the
   loop reports how many of them it sent. */
static void take(lean_object *pair, lean_object **state, uint8_t *out, size_t cap, ekk_action *act) {
    lean_object *s = lean_ctor_get(pair, 0);
    lean_object *a = lean_ctor_get(pair, 1);
    lean_inc(s);
    lean_inc(a);
    lean_dec(pair);
    *state = s;
    act->kind = (uint8_t)lean_obj_tag(a);
    act->room = 0;
    act->len = 0;
    act->query = NULL;
    if (act->kind == 4) {
        act->query = lean_ctor_get(a, 0);
        lean_inc(act->query);
    } else if (act->kind == 0) {
        act->room = lean_usize_of_nat(lean_ctor_get(a, 0));
    } else if (act->kind == 1) {
        lean_object *data = lean_ctor_get(a, 0);
        size_t off = lean_usize_of_nat(lean_ctor_get(a, 1));
        size_t n = lean_sarray_size(data) - off; /* Conn.step_send: off < size */
        if (n > cap) n = cap;
        memcpy(out, lean_sarray_cptr(data) + off, n);
        act->len = n;
    }
    lean_dec(a);
}

void ekk_open(lean_object **state, uint8_t *out, size_t cap, ekk_action *act) {
    take(ekk_conn_open(0), state, out, cap, act);
}

/* The receive returned data[0..n); n == 0 means the peer closed its side. */
void ekk_recv(lean_object **state, const uint8_t *data, size_t n, uint8_t *out, size_t cap, ekk_action *act) {
    lean_object *a = lean_alloc_sarray(1, n, n);
    memcpy(lean_sarray_cptr(a), data, n);
    take(ekk_conn_on_recv((uint64_t)time(NULL), *state, a), state, out, cap, act);
}

void ekk_sent(lean_object **state, size_t n, uint8_t *out, size_t cap, ekk_action *act) {
    take(ekk_conn_on_sent((uint64_t)time(NULL), *state, n), state, out, cap, act);
}

void ekk_fail(lean_object **state, uint8_t *out, size_t cap, ekk_action *act) {
    take(ekk_conn_on_fail(*state), state, out, cap, act);
}

/* The loop shuts down and declines the receive Lean asked for (or canceled
   the one in flight); Conn.step answers it with close. */
void ekk_refused(lean_object **state, uint8_t *out, size_t cap, ekk_action *act) {
    take(ekk_conn_on_refused(*state), state, out, cap, act);
}

void ekk_free(lean_object *state) { lean_dec(state); }

/* A Lean String's bytes, NUL-terminated (Transport.main rejects a NUL). */
const char *ekk_string_cstr(lean_object *s) { return lean_string_cstr(s); }

/* The query Lean asked for answered `result` (owned; passed on to Lean). */
void ekk_answer(lean_object **state, lean_object *result, uint8_t *out, size_t cap, ekk_action *act) {
    take(ekk_conn_on_answer((uint64_t)time(NULL), *state, result), state, out, cap, act);
}

/* ---- PostgreSQL (libpq), called by zig/src/pg.zig on its loop's thread ----
   Values cross into Lean as Server.Query and Server.Query.Result
   (lean/Server/Query.lean). Layouts: Query is a structure, constructor 0 with
   fields sql, params; Option: none = box(0), some = constructor 1 with one
   field; Result.rows = constructor 0 (columns, rows), Result.error =
   constructor 1 (sqlstate, message). */

/* Query.maxResultBytes in lean/Server/Query.lean. */
#define EKK_MAX_RESULT_BYTES 1048576

void ekk_query_drop(lean_object *q) { lean_dec(q); }

lean_object *ekk_pg_error(const char *sqlstate, const char *message) {
    lean_object *r = lean_alloc_ctor(1, 2, 0);
    lean_ctor_set(r, 0, lean_mk_string(sqlstate));
    lean_ctor_set(r, 1, lean_mk_string(message ? message : ""));
    return r;
}

/* A pool slot's session: the libpq connection, in non-blocking pipeline mode,
   and the statements prepared on it. Each Query.sql gets a named statement
   on its first use on the connection (Prepare, then its execution, in one
   pipeline with one Sync: one round trip) and is executed by name after
   that, as pgx's statement cache does; once EKK_STATEMENTS are prepared,
   further SQL texts run as unnamed statements. A Query must therefore not
   deallocate statements (DEALLOCATE, DISCARD ALL). One query is in flight
   per session (pg.zig). */
#define EKK_STATEMENTS 64

typedef struct {
    PGconn *c;
    char *sql[EKK_STATEMENTS]; /* sql[i] is prepared as statement "ekk<i>" */
    int prepared;
    int preparing; /* the query in flight prepares sql[prepared - 1] first */
    int last_null; /* PQgetResult's last return was NULL */
} ekk_pg;

/* The connection's last error, for a lost connection: class 08006. */
lean_object *ekk_pg_lost(ekk_pg *p) {
    return ekk_pg_error("08006", p && p->c ? PQerrorMessage(p->c) : "could not connect");
}

/* Starts a non-blocking connection (PQconnectStartParams). The conninfo is
   expanded as dbname; client_encoding=UTF8 after it overrides any given there.
   The conninfo must name a Unix socket directory or a hostaddr: resolving a
   host name would block the loop. NULL when there is no memory. */
ekk_pg *ekk_pg_start(const char *conninfo) {
    const char *keys[] = {"dbname", "client_encoding", NULL};
    const char *vals[] = {conninfo, "UTF8", NULL};
    ekk_pg *p = calloc(1, sizeof *p);
    if (p == NULL) return NULL;
    p->c = PQconnectStartParams(keys, vals, 1);
    if (p->c == NULL) { free(p); return NULL; }
    return p;
}

/* One PQconnectPoll step: 0 failed, 1 wait to read, 2 wait to write,
   3 connected (now in non-blocking pipeline mode). */
int ekk_pg_connect_poll(ekk_pg *p) {
    if (PQstatus(p->c) == CONNECTION_BAD) return 0;
    switch (PQconnectPoll(p->c)) {
    case PGRES_POLLING_READING: return 1;
    case PGRES_POLLING_WRITING: return 2;
    case PGRES_POLLING_OK:
        return PQsetnonblocking(p->c, 1) == 0 && PQenterPipelineMode(p->c) ? 3 : 0;
    default: return 0;
    }
}

int ekk_pg_socket(ekk_pg *p) { return PQsocket(p->c); }

void ekk_pg_finish(ekk_pg *p) {
    PQfinish(p->c);
    for (int i = 0; i < p->prepared; i++) free(p->sql[i]);
    free(p);
}

/* A close-on-exec duplicate of `fd`, owned by the loop, or -1. */
int ekk_dup(int fd) { return fcntl(fd, F_DUPFD_CLOEXEC, 0); }

/* A Lean string's bytes as a C string, or NULL when it holds a NUL. */
static const char *cstr(lean_object *s) {
    const char *p = lean_string_cstr(s);
    return strlen(p) + 1 == lean_string_size(s) ? p : NULL;
}

/* Sends query `q` (consumed) and a Sync, with text parameters and results:
   by its statement's name, preparing it first on its first use. 0 sent
   (flush with ekk_pg_flush); 1 not sent, *err holds the error Result and the
   connection is unchanged; 2 the connection failed. */
int ekk_pg_send(ekk_pg *p, lean_object *q, lean_object **err) {
    lean_object *sql = lean_ctor_get(q, 0);
    lean_object *params = lean_ctor_get(q, 1);
    size_t n = lean_array_size(params);
    int rc = 0;
    const char **vals = NULL;
    const char *text = cstr(sql);
    *err = NULL;
    p->preparing = 0;
    p->last_null = 0;
    if (text == NULL || n > 65535) {
        *err = ekk_pg_error("54000", text == NULL ? "a NUL character in the SQL" : "more than 65535 parameters");
        rc = 1;
        goto done;
    }
    if (n > 0) {
        vals = malloc(n * sizeof *vals);
        if (vals == NULL) { *err = ekk_pg_error("53200", "out of memory"); rc = 1; goto done; }
    }
    for (size_t i = 0; i < n; i++) {
        lean_object *o = lean_array_get_core(params, i);
        if (lean_is_scalar(o)) { vals[i] = NULL; continue; }
        vals[i] = cstr(lean_ctor_get(o, 0));
        if (vals[i] == NULL) { *err = ekk_pg_error("54000", "a NUL character in a parameter"); rc = 1; goto done; }
    }
    int k = 0;
    while (k < p->prepared && strcmp(p->sql[k], text) != 0) k++;
    char name[16];
    snprintf(name, sizeof name, "ekk%d", k);
    int ok;
    if (k < p->prepared) {
        ok = PQsendQueryPrepared(p->c, name, (int)n, vals, NULL, NULL, 0);
    } else if (k < EKK_STATEMENTS && (p->sql[k] = strdup(text)) != NULL) {
        p->prepared++;
        p->preparing = 1;
        ok = PQsendPrepare(p->c, name, text, (int)n, NULL)
            && PQsendQueryPrepared(p->c, name, (int)n, vals, NULL, NULL, 0);
    } else {
        ok = PQsendQueryParams(p->c, text, (int)n, NULL, vals, NULL, NULL, 0);
    }
    rc = ok && PQpipelineSync(p->c) ? 0 : 2;
done:
    free(vals);
    lean_dec(q);
    return rc;
}

/* PQflush: 0 all sent, 1 more to send (wait to write), -1 failed. */
int ekk_pg_flush(ekk_pg *p) { return PQflush(p->c); }

/* Reads what has arrived: 1 ok, 0 the connection failed. */
int ekk_pg_consume(ekk_pg *p) {
    return PQconsumeInput(p->c) && PQstatus(p->c) == CONNECTION_OK;
}

/* A PGresult with rows as Result.rows, or Result.error when its text exceeds
   EKK_MAX_RESULT_BYTES. */
static lean_object *rows_of(PGresult *r) {
    int nf = PQnfields(r), nt = PQntuples(r);
    size_t total = 0;
    for (int f = 0; f < nf; f++) total += strlen(PQfname(r, f));
    for (int t = 0; t < nt && total <= EKK_MAX_RESULT_BYTES; t++)
        for (int f = 0; f < nf; f++) total += (size_t)PQgetlength(r, t, f);
    if (total > EKK_MAX_RESULT_BYTES) return ekk_pg_error("54000", "the result exceeds Query.maxResultBytes");
    lean_object *cols = lean_alloc_array(0, nf);
    for (int f = 0; f < nf; f++) cols = lean_array_push(cols, lean_mk_string(PQfname(r, f)));
    lean_object *rows = lean_alloc_array(0, nt);
    for (int t = 0; t < nt; t++) {
        lean_object *row = lean_alloc_array(0, nf);
        for (int f = 0; f < nf; f++) {
            lean_object *v;
            if (PQgetisnull(r, t, f)) v = lean_box(0);
            else {
                v = lean_alloc_ctor(1, 1, 0);
                /* Validates the UTF-8 (invalid bytes become U+FFFD). */
                lean_ctor_set(v, 0, lean_mk_string_from_bytes(PQgetvalue(r, t, f), (size_t)PQgetlength(r, t, f)));
            }
            row = lean_array_push(row, v);
        }
        rows = lean_array_push(rows, row);
    }
    lean_object *res = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(res, 0, cols);
    lean_ctor_set(res, 1, rows);
    return res;
}

static lean_object *error_of(PGresult *r) {
    const char *st = PQresultErrorField(r, PG_DIAG_SQLSTATE);
    return ekk_pg_error(st ? st : "XX000", PQresultErrorMessage(r));
}

/* Collects the results that have arrived, without blocking, until the
   query's Sync. *acc holds the query's Result: its last result (a later
   error wins over earlier rows), or the error of preparing its statement
   (which is then forgotten, and the execution PostgreSQL skipped is
   ignored). 1 when the Sync arrived (*acc is complete), 0 when more input is
   needed, -1 when the connection failed, the statement started COPY, which
   this pool does not speak, or it left a transaction open: the connection
   must be closed (*acc holds an error). */
int ekk_pg_collect(ekk_pg *p, lean_object **acc) {
    while (!PQisBusy(p->c)) {
        PGresult *r = PQgetResult(p->c);
        if (r == NULL) {
            /* A NULL ends one command's results; two in a row mean nothing is
               pending, so the Sync can never come. */
            if (p->last_null || PQstatus(p->c) != CONNECTION_OK) {
                if (*acc) lean_dec(*acc);
                *acc = ekk_pg_lost(p);
                return -1;
            }
            p->last_null = 1;
            continue;
        }
        p->last_null = 0;
        lean_object *v = NULL;
        int stop = 0;
        switch (PQresultStatus(r)) {
        case PGRES_PIPELINE_SYNC:
            PQclear(r);
            if (*acc == NULL) *acc = ekk_pg_error("08006", "no result");
            if (PQtransactionStatus(p->c) != PQTRANS_IDLE) {
                /* The query left a transaction open or failed (Query.lean):
                   the session is closed, which rolls it back. */
                lean_dec(*acc);
                *acc = ekk_pg_error("25000", "the query left a transaction open; it was rolled back");
                return -1;
            }
            return 1;
        case PGRES_PIPELINE_ABORTED:
            break; /* skipped after the error already in *acc */
        case PGRES_COMMAND_OK:
            if (p->preparing) { p->preparing = 0; break; } /* the statement is prepared */
            v = rows_of(r);
            break;
        case PGRES_TUPLES_OK:
        case PGRES_EMPTY_QUERY:
            v = rows_of(r);
            break;
        case PGRES_COPY_IN:
        case PGRES_COPY_OUT:
        case PGRES_COPY_BOTH:
            v = ekk_pg_error("0A000", "COPY is not supported");
            stop = 1;
            break;
        default:
            if (p->preparing) {
                /* Preparing failed: forget the statement. */
                p->preparing = 0;
                p->prepared--;
                free(p->sql[p->prepared]);
            }
            v = error_of(r);
        }
        PQclear(r);
        if (v) {
            if (*acc) lean_dec(*acc);
            *acc = v;
        }
        if (stop) return -1;
    }
    return 0;
}

/* Shutdown signals: SIGTERM and SIGINT write one byte to a pipe that a thread
   of serve.zig reads (the only async-signal-safe way to hand it over). The
   write end is non-blocking: when the pipe is full a stop is already
   pending, and the byte is not needed. */
static int stop_fd = -1;

static void on_stop_signal(int sig) {
    (void)sig;
    int saved = errno;
    char b = 1;
    ssize_t r = write(stop_fd, &b, 1);
    (void)r;
    errno = saved;
}

/* Installs the handlers; returns the pipe's read end, or -1. */
int ekk_stop_signals(void) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    if (fcntl(fds[1], F_SETFL, O_NONBLOCK) != 0) return -1;
    stop_fd = fds[1];
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_stop_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    if (sigaction(SIGTERM, &sa, NULL) != 0 || sigaction(SIGINT, &sa, NULL) != 0) return -1;
    return fds[0];
}

/* Makes room for `need` open descriptors (the soft RLIMIT_NOFILE, raised up
   to the hard limit when lower); returns 0 when there is room. */
int ekk_fd_room(unsigned long need) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) return -1;
    if (rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur < need) {
        if (rl.rlim_max != RLIM_INFINITY && rl.rlim_max < need) return -1;
        rl.rlim_cur = need;
        if (setrlimit(RLIMIT_NOFILE, &rl) != 0) return -1;
    }
    return 0;
}

/* Test setting only (--crash-after-recv, --crash-after-send): ends the
   process, as a crash would, without running any handler. raise() sends
   SIGKILL to the calling thread, so this thread performs nothing more; a
   kill() of the whole process may deliver it to another thread and let this
   one run on (seen: one more send reached the peer). Never returns. */
void ekk_crash(void) {
    raise(SIGKILL);
    for (;;) pause();
}
