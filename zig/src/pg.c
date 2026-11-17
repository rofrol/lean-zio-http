/* The PostgreSQL glue of zig/src/pg.zig: libpq calls and the Lean values of
   Server.Query and its results. Its own file so that the tests
   (pg_glue_test.c) link it without the Lean program glue.c serves. */
#include <lean/lean.h>
#include <libpq-fe.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
   that, as pgx's statement cache does; once EKK_STATEMENTS are cached,
   further SQL texts run as unnamed statements. A Query must therefore not
   deallocate statements (DEALLOCATE, DISCARD ALL). One query is in flight
   per session (pg.zig).

   A cached statement whose execution fails because its plan went stale
   (`invalidated`: a schema change altered its result type, or the server
   no longer has it) is forgotten, and that query is answered with the
   error, never sent again; the text's next use prepares it afresh. Names
   come from a counter and are never reused within a session, so preparing
   cannot collide with a forgotten statement the server still holds; those
   are counted in `stale`, and a session that reaches EKK_STATEMENTS of them
   is closed after the query's result, which bounds what it leaves on the
   server. */
#define EKK_STATEMENTS 64

typedef struct {
    PGconn *c;
    char *sql[EKK_STATEMENTS];       /* sql[i] is prepared as "ekk<name[i]>" */
    unsigned long long name[EKK_STATEMENTS];
    int prepared;                    /* entries in sql and name */
    unsigned long long next_name;    /* the next statement's name; never reused */
    int stale;                       /* forgotten statements perhaps still on the server */
    int preparing; /* the query in flight prepares sql[prepared - 1] first */
    int cached;    /* the query in flight executes the entry prepared before, or -1 */
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
    p->cached = -1;
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
    char name[32];
    int ok;
    if (k < p->prepared) {
        snprintf(name, sizeof name, "ekk%llu", p->name[k]);
        p->cached = k;
        ok = PQsendQueryPrepared(p->c, name, (int)n, vals, NULL, NULL, 0);
    } else if (k < EKK_STATEMENTS && (p->sql[k] = strdup(text)) != NULL) {
        p->name[k] = p->next_name++;
        snprintf(name, sizeof name, "ekk%llu", p->name[k]);
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

/* ---- What a result costs (Query.maxResultBytes) ----
   rows_of charges, before it allocates anything, every Lean object it would
   build: the Result, the column array and each column name, the row array,
   each row's array (one slot per field, so a NULL or empty value costs its
   slot), and for each non-NULL value its `some` and its string. Each object
   costs what lean_alloc_object or lean_alloc_ctor asks for, rounded up to
   LEAN_OBJECT_SIZE_DELTA, plus one word for the size a big object's
   allocation keeps before it (lean.h). The arithmetic saturates at SIZE_MAX,
   which no limit reaches. This bounds the result it hands to Lean, not the
   PGresult libpq built before (qsqb5f), nor the allocator's own overhead. */

/* Adds `n` to *total: 0 once the sum exceeds `limit` (or overflows). */
static int charge(size_t *total, size_t n, size_t limit) {
    return !__builtin_add_overflow(*total, n, total) && *total <= limit;
}

/* What an object of `fixed` bytes and `n` words more costs; SIZE_MAX on
   overflow. */
static size_t object_cost(size_t fixed, size_t n) {
    size_t sz;
    if (__builtin_mul_overflow(n, sizeof(void *), &sz) || __builtin_add_overflow(sz, fixed, &sz)
        || __builtin_add_overflow(sz, LEAN_OBJECT_SIZE_DELTA - 1 + sizeof(size_t), &sz))
        return SIZE_MAX;
    return sz / LEAN_OBJECT_SIZE_DELTA * LEAN_OBJECT_SIZE_DELTA;
}

/* Whether s[0..n) is UTF-8 as RFC 3629 defines it, as Lean's runtime
   checks it (validate_utf8_one in src/runtime/utf8.cpp): no overlong forms,
   no surrogates, nothing above U+10FFFF. */
static int utf8_valid(const unsigned char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned c = s[i];
        size_t k;
        unsigned v, min;
        if (c < 0x80) { i++; continue; }
        if ((c & 0xe0) == 0xc0) { k = 1; v = c & 0x1f; min = 0x80; }
        else if ((c & 0xf0) == 0xe0) { k = 2; v = c & 0x0f; min = 0x800; }
        else if ((c & 0xf8) == 0xf0) { k = 3; v = c & 0x07; min = 0x10000; }
        else return 0;
        if (n - i <= k) return 0;
        for (size_t j = 1; j <= k; j++) {
            if ((s[i + j] & 0xc0) != 0x80) return 0;
            v = v << 6 | (s[i + j] & 0x3f);
        }
        if (v < min || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) return 0;
        i += k + 1;
    }
    return 1;
}

/* What the Lean string of `n` bytes, `valid` UTF-8 or not, costs.
   lean_mk_string_from_bytes keeps valid UTF-8 as it is and replaces each
   invalid sequence, at least one byte, with U+FFFD, three bytes
   (lean_mk_string_lossy_recover in src/runtime/object.cpp), so invalid
   bytes are charged three times; the string adds its NUL. */
static size_t string_cost(size_t n, int valid) {
    size_t bytes;
    if (!valid && __builtin_mul_overflow(n, 3, &n)) return SIZE_MAX;
    if (__builtin_add_overflow(n, sizeof(lean_string_object) + 1, &bytes)) return SIZE_MAX;
    return object_cost(bytes, 0);
}

/* Charges the Lean string of s[0..n). Its least cost is charged first, so
   the bytes are checked only when they fit: the work stays proportional
   to the limit too. */
static int charge_text(size_t *total, const char *s, size_t n, size_t limit) {
    size_t least = *total;
    if (!charge(&least, string_cost(n, 1), limit)) return 0;
    return charge(total, string_cost(n, utf8_valid((const unsigned char *)s, n)), limit);
}

/* Whether the Result rows_of builds from `r` costs at most `limit` bytes
   (less than SIZE_MAX). */
static int result_fits(PGresult *r, size_t limit) {
    int nf = PQnfields(r), nt = PQntuples(r);
    size_t total = 0;
    if (!charge(&total, object_cost(sizeof(lean_ctor_object), 2), limit)
        || !charge(&total, object_cost(sizeof(lean_array_object), (size_t)nf), limit)
        || !charge(&total, object_cost(sizeof(lean_array_object), (size_t)nt), limit))
        return 0;
    for (int f = 0; f < nf; f++) {
        const char *name = PQfname(r, f);
        size_t n = strnlen(name, limit + 1);
        if (n > limit || !charge_text(&total, name, n, limit)) return 0;
    }
    size_t row = object_cost(sizeof(lean_array_object), (size_t)nf), some = object_cost(sizeof(lean_ctor_object), 1);
    for (int t = 0; t < nt; t++) {
        if (!charge(&total, row, limit)) return 0;
        for (int f = 0; f < nf; f++) {
            if (PQgetisnull(r, t, f)) continue;
            if (!charge(&total, some, limit)
                || !charge_text(&total, PQgetvalue(r, t, f), (size_t)PQgetlength(r, t, f), limit))
                return 0;
        }
    }
    return 1;
}

/* A PGresult with rows as Result.rows, or Result.error when that would cost
   more than `limit` bytes (result_fits). */
static lean_object *rows_within(PGresult *r, size_t limit) {
    if (!result_fits(r, limit)) return ekk_pg_error("54000", "the result exceeds Query.maxResultBytes");
    int nf = PQnfields(r), nt = PQntuples(r);
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

static lean_object *rows_of(PGresult *r) { return rows_within(r, EKK_MAX_RESULT_BYTES); }

/* Forgets cache entry k, keeping the others in order. */
static void forget(ekk_pg *p, int k) {
    free(p->sql[k]);
    p->prepared--;
    memmove(p->sql + k, p->sql + k + 1, (size_t)(p->prepared - k) * sizeof p->sql[0]);
    memmove(p->name + k, p->name + k + 1, (size_t)(p->prepared - k) * sizeof p->name[0]);
}

/* An execution of a cached statement failed because the statement went
   stale: 0A000 raised by RevalidateCachedQuery, PostgreSQL's "cached plan
   must not change result type" (the routine, field R, is sent with every
   error and is not translated as the message is; PostgreSQL 14 to 18
   raise it there, recheck when that changes), or 26000, no such prepared
   statement. A 26000 may also come from a statement that runs EXECUTE
   itself; forgetting the entry then costs only a fresh Prepare under a new
   name, and the count in `stale`. */
static int invalidated(PGresult *r) {
    const char *st = PQresultErrorField(r, PG_DIAG_SQLSTATE);
    const char *fn = PQresultErrorField(r, PG_DIAG_SOURCE_FUNCTION);
    if (st == NULL) return 0;
    if (strcmp(st, "26000") == 0) return 1;
    return strcmp(st, "0A000") == 0 && fn != NULL && strcmp(fn, "RevalidateCachedQuery") == 0;
}

static lean_object *error_of(PGresult *r) {
    const char *st = PQresultErrorField(r, PG_DIAG_SQLSTATE);
    return ekk_pg_error(st ? st : "XX000", PQresultErrorMessage(r));
}

/* Collects the results that have arrived, without blocking, until the
   query's Sync. *acc holds the query's Result: its last result (a later
   error wins over earlier rows), or the error of preparing its statement
   (which is then forgotten, and the execution PostgreSQL skipped is
   ignored). A cached statement that went stale is forgotten (`invalidated`).
   1 when the Sync arrived (*acc is complete), 0 when more input is needed,
   -1 when the session must be closed, with *acc the query's result: an
   error when the connection failed, the statement started COPY, which this
   pool does not speak, or it left a transaction open; the query's own
   result when the session holds EKK_STATEMENTS stale statements. */
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
            return p->stale >= EKK_STATEMENTS ? -1 : 1;
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
                /* Preparing failed: forget the statement, which the server
                   does not hold. */
                p->preparing = 0;
                forget(p, p->prepared - 1);
            } else if (p->cached >= 0 && invalidated(r)) {
                forget(p, p->cached);
                p->cached = -1;
                p->stale++;
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
