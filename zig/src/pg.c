/* The PostgreSQL glue of zig/src/pg.zig: libpq calls and the Lean values of
   Server.Query and its results. Its own file so that the tests
   (pg_glue_test.c) link it without the Lean program glue.c serves. */
#include <lean/lean.h>
#include <libpq-fe.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* PQsetChunkedRowsMode, which every execution uses, and
   PQsendClosePrepared (below) came with libpq 17. */
#ifndef LIBPQ_HAS_CHUNK_MODE
#error "the PostgreSQL pool needs libpq 17 or later (PQsetChunkedRowsMode)"
#endif

/* ---- PostgreSQL (libpq), called by zig/src/pg.zig on its loop's thread ----
   Values cross into Lean as Server.Query and Server.Query.Result
   (lean/Server/Query.lean). Layouts: Query is a structure, constructor 0 with
   fields sql, params, timeoutMs (an Option Nat); Option: none = box(0), some = constructor 1 with one
   field; Result.rows = constructor 0 (columns, rows), Result.error =
   constructor 1 (sqlstate, message), Result.abandoned = constructor 2
   (sqlstate, message). */

/* Query.maxResultBytes in Server/Query.lean; lsrv-test (Test.lean,
   resultBoundAgrees) reads the line below and fails when the two differ.
   It must stay the only line naming the bound with the preprocessor's
   keyword, its value a plain decimal number. */
#define EKK_MAX_RESULT_BYTES 1048576

void ekk_query_drop(lean_object *q) { lean_dec(q); }

static lean_object *failure(unsigned tag, const char *sqlstate, const char *message) {
    lean_object *r = lean_alloc_ctor(tag, 2, 0);
    lean_ctor_set(r, 0, lean_mk_string(sqlstate));
    lean_ctor_set(r, 1, lean_mk_string(message ? message : ""));
    return r;
}

/* Result.error: the statement failed or did not run. */
lean_object *ekk_pg_error(const char *sqlstate, const char *message) { return failure(1, sqlstate, message); }

/* Result.abandoned: the pool gave the statement up after it may have
   reached the database, so its outcome is unknown. */
lean_object *ekk_pg_abandoned(const char *sqlstate, const char *message) { return failure(2, sqlstate, message); }

/* A pool slot's session: the libpq connection, in non-blocking pipeline mode,
   and the statements prepared on it. Each Query.sql gets a named statement
   on its first use on the connection (Prepare, then its execution, in one
   pipeline with one Sync: one round trip) and is executed by name after
   that, as pgx's statement cache does; once EKK_STATEMENTS are cached,
   further SQL texts run as unnamed statements. A Query must therefore not
   deallocate statements (DEALLOCATE, DISCARD ALL). One query is in flight
   per session (pg.zig).

   A cached statement whose execution fails with 0A000 or 26000 (`evicts`)
   is forgotten, and that query is answered with the error, never sent
   again; the text's next use prepares it afresh under a new name (names
   come from a counter and are never reused within a session). After the
   query's Sync, when no transaction is open, the forgotten statement is
   closed on the server (a Close with a Sync of its own) before the answer
   is delivered, so the server holds exactly the statements cached here; a
   session whose Close fails is closed.

   Every execution runs in libpq's chunked-rows mode, so its rows arrive
   in PGresults of EKK_CHUNK_ROWS rows (the last one of fewer) and are
   charged against Query.maxResultBytes as they arrive (ekk_rows); a result
   that crosses the bound closes the session before the rest arrives. The
   mode is set for a cached or unnamed execution right after sending it,
   and on a first use once the Prepare's results have ended (`stage`),
   before the execution's first PQgetResult. libpq 17's documentation
   ("Retrieving Query Results in Chunks") allows the second in pipeline
   mode, which every session is in: "When using pipeline mode,
   single-row or chunked mode needs to be activated for each query in the
   pipeline before retrieving results for that query with PQgetResult."
   Its general rule, "immediately after PQsendQuery or one of its sibling
   functions, before any other operation on the connection such as
   PQconsumeInput or PQgetResult" (PQsetChunkedRowsMode), is kept by the
   first. */
#define EKK_STATEMENTS 64

/* The rows of one chunk. libpq hands a chunk over only once it holds this
   many rows or the execution's rows have ended, so it copies at most
   EKK_CHUNK_ROWS - 1 rows after the one that crosses the bound before the
   pool sees that row (docs/postgresql.md, "Bounded only in part"). The smallest size
   measured that gets single-row mode's per-row cost back: chunks of 16
   and 64 cost the same within noise, so the smaller residual decides
   (bench/rows.sh, docs/reports/postgresql-throughput.md). */
#define EKK_CHUNK_ROWS 16

/* Where the query in flight is in its commands. */
typedef enum {
    EKK_PREPARING, /* the Prepare's result comes first */
    EKK_PREPARED,  /* the Prepare succeeded; the NULL ending it comes next */
    EKK_EXECUTING, /* the execution's results, in chunked-rows mode */
    EKK_SKIPPED,   /* preparing failed, so PostgreSQL skips the execution */
    EKK_CLOSING,   /* answered; the Close of the forgotten statement comes next */
    EKK_CLOSED,    /* the Close succeeded; its Sync comes next */
} ekk_stage;

/* The Result.rows of the query in flight, built as its rows arrive. `cost`
   is what the finished Result costs so far, by the measure of
   Query.maxResultBytes (below); `cols` is NULL until a result has
   described the columns. */
typedef struct {
    lean_object *cols;
    lean_object *rows;
    size_t cost;
} ekk_rows;

typedef struct {
    PGconn *c;
    char *sql[EKK_STATEMENTS];       /* sql[i] is prepared as "ekk<name[i]>" */
    unsigned long long name[EKK_STATEMENTS];
    int prepared;                    /* entries in sql and name */
    unsigned long long next_name;    /* the next statement's name; never reused */
    int evicted;                     /* the query in flight forgot a cached entry... */
    unsigned long long evicted_name; /* ...of this name, to close after its Sync */
    ekk_stage stage; /* EKK_PREPARING..: the query in flight prepares sql[prepared - 1] */
    int cached;    /* the query in flight executes the entry prepared before, or -1 */
    int last_null; /* PQgetResult's last return was NULL */
    ekk_rows rows; /* the query in flight's rows so far */
    size_t limit;  /* EKK_MAX_RESULT_BYTES; the tests (pg_glue_test.c) set less */
    int chunk;     /* EKK_CHUNK_ROWS; the tests set others */
} ekk_pg;

/* The name statement `n` is prepared under. */
static void stmt_name(char out[32], unsigned long long n) { snprintf(out, 32, "ekk%llu", n); }

/* libpq's chunked-rows mode for the command at the head of libpq's queue.
   The callers set it only where libpq's documentation allows it (above),
   so a refusal is a programming error, never a reason to buffer the whole
   result. */
static void chunked(ekk_pg *p) {
    if (!PQsetChunkedRowsMode(p->c, p->chunk)) {
        fprintf(stderr, "pg.c: libpq refused chunked-rows mode for the execution\n");
        abort();
    }
}

/* Whether the libpq the process runs supports the pool: chunked-rows mode
   (PQsetChunkedRowsMode), from 17.0. `v` is PQlibVersion's
   major * 10000 + minor. */
static int libpq_supported(int v) { return v >= 170000; }

int ekk_pg_libpq_supported(void) { return libpq_supported(PQlibVersion()); }

int ekk_pg_libpq_version(void) { return PQlibVersion(); }

static void rows_drop(ekk_rows *b);

/* The connection's last error, for a connection that could not be made or
   a query proven never sent: Result.error 08006. */
lean_object *ekk_pg_lost(ekk_pg *p) {
    return ekk_pg_error("08006", p && p->c ? PQerrorMessage(p->c) : "could not connect");
}

/* The connection's last error, for a connection lost after the query was
   handed to libpq: Result.abandoned 08006, since PostgreSQL may have run
   it. Handing it over is the boundary (Server.Query): libpq documents no
   point before which a failed send call or an unflushed output buffer
   proves that nothing reached the server. */
lean_object *ekk_pg_lost_sent(ekk_pg *p) {
    return ekk_pg_abandoned("08006", p && p->c ? PQerrorMessage(p->c) : "the connection was lost");
}

/* The completion budget query `q` asks for (Query.timeoutMs) in
   milliseconds: `dflt` for none, the value itself from 1 to `ceiling`, 0
   for any other value (the pool answers it 22023 without sending it). */
unsigned ekk_query_timeout_ms(lean_object *q, unsigned dflt, unsigned ceiling) {
    lean_object *t = lean_ctor_get(q, 2);
    if (lean_is_scalar(t)) return dflt; /* none */
    lean_object *n = lean_ctor_get(t, 0);
    if (!lean_is_scalar(n)) return 0; /* a Nat beyond a machine word */
    size_t v = lean_unbox(n);
    return v >= 1 && v <= ceiling ? (unsigned)v : 0;
}

/* The startup `options` every session sends: the conninfo's own `options`
   (or else PGOPTIONS), then `-c statement_timeout=MS`, which PostgreSQL
   applies after them, so it overrides one given there. 0 with *out set
   (malloc'd); 1 when the conninfo or PGSERVICE names a service, whose file
   may hold options this explicit value would replace; 2 out of memory;
   3 when those options end in an unpaired backslash, which PostgreSQL
   would read as escaping the separator, joining the next token to the
   last one (its option splitting, pg_split_opts); 4 with *out set
   (malloc'd) to libpq's message when the conninfo does not parse
   (PQconninfoParse: "If errmsg is not NULL, then *errmsg is set to NULL on
   success, else to a malloc'd error string explaining the problem").
   PQconninfoParse returns NULL with no message only when out of memory
   (that passage: "It is also possible for *errmsg to be set to NULL and the
   function to return NULL; this indicates an out-of-memory condition"). */
int ekk_pg_options(const char *conninfo, unsigned statement_ms, char **out) {
    const char *base = NULL;
    int named_service = getenv("PGSERVICE") != NULL;
    char *err = NULL;
    PQconninfoOption *opts = PQconninfoParse(conninfo, &err);
    if (opts == NULL) {
        if (err == NULL) return 2;
        size_t n = strlen(err) + 1;
        *out = malloc(n);
        if (*out != NULL) memcpy(*out, err, n);
        PQfreemem(err);
        return *out == NULL ? 2 : 4;
    }
    for (PQconninfoOption *o = opts; o && o->keyword; o++) {
        if (o->val == NULL) continue;
        if (strcmp(o->keyword, "service") == 0) named_service = 1;
        if (strcmp(o->keyword, "options") == 0) base = o->val;
    }
    if (base == NULL) base = getenv("PGOPTIONS");
    int rc = 0;
    size_t tail = 0;
    for (size_t k = base ? strlen(base) : 0; k > 0 && base[k - 1] == '\\'; k--) tail++;
    if (named_service) rc = 1;
    else if (tail % 2 == 1) rc = 3;
    else {
        size_t n = (base ? strlen(base) : 0) + 64;
        *out = malloc(n);
        if (*out == NULL) rc = 2;
        else snprintf(*out, n, "%s%s-c statement_timeout=%u", base ? base : "", base && *base ? " " : "", statement_ms);
    }
    if (opts) PQconninfoFree(opts);
    return rc;
}

/* Starts a non-blocking connection (PQconnectStartParams). The conninfo is
   expanded as dbname; client_encoding=UTF8 and `options` (ekk_pg_options)
   after it override any given there. The conninfo must name a Unix socket
   directory or a hostaddr: resolving a host name would block the loop.
   NULL when there is no memory. */
ekk_pg *ekk_pg_start(const char *conninfo, const char *options) {
    const char *keys[] = {"dbname", "client_encoding", "options", NULL};
    const char *vals[] = {conninfo, "UTF8", options, NULL};
    ekk_pg *p = calloc(1, sizeof *p);
    if (p == NULL) return NULL;
    p->limit = EKK_MAX_RESULT_BYTES;
    p->chunk = EKK_CHUNK_ROWS;
    p->c = PQconnectStartParams(keys, vals, 1);
    if (p->c == NULL) { free(p); return NULL; }
    return p;
}

/* The step before the first PQconnectPoll: 0 failed (PQstatus is
   CONNECTION_BAD, the attempt failed at its start), 2 wait to write.
   libpq 17's documentation (PQconnectStartParams): "Next call
   PQstatus(conn). If the result is CONNECTION_BAD, the connection attempt
   has already failed", and of the PQconnectPoll loop: "On the first
   iteration, i.e., if you have yet to call PQconnectPoll, behave as if it
   last returned PGRES_POLLING_WRITING." */
int ekk_pg_connect_first(ekk_pg *p) { return PQstatus(p->c) == CONNECTION_BAD ? 0 : 2; }

/* One PQconnectPoll step, once the socket is ready the way the step
   before asked (ekk_pg_connect_first, then this): 0 failed, 1 wait to
   read, 2 wait to write, 3 connected (now in non-blocking pipeline
   mode). */
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
    rows_drop(&p->rows);
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
   connection is unchanged; 2 the connection failed after the query was
   handed to libpq (it may have reached the server); 3 the connection had
   already failed, so nothing of the query was handed to libpq (libpq's
   send functions refuse a connection whose status is not CONNECTION_OK
   before they queue anything). */
int ekk_pg_send(ekk_pg *p, lean_object *q, lean_object **err) {
    lean_object *sql = lean_ctor_get(q, 0);
    lean_object *params = lean_ctor_get(q, 1);
    size_t n = lean_array_size(params);
    int rc = 0;
    const char **vals = NULL;
    const char *text = cstr(sql);
    *err = NULL;
    p->stage = EKK_EXECUTING;
    p->cached = -1;
    p->evicted = 0;
    p->last_null = 0;
    rows_drop(&p->rows);
    if (PQstatus(p->c) != CONNECTION_OK) {
        rc = 3;
        goto done;
    }
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
        stmt_name(name, p->name[k]);
        p->cached = k;
        ok = PQsendQueryPrepared(p->c, name, (int)n, vals, NULL, NULL, 0);
        if (ok) chunked(p);
    } else if (k < EKK_STATEMENTS && (p->sql[k] = strdup(text)) != NULL) {
        p->name[k] = p->next_name++;
        stmt_name(name, p->name[k]);
        p->prepared++;
        p->stage = EKK_PREPARING; /* chunked-rows mode once the Prepare's results end */
        ok = PQsendPrepare(p->c, name, text, (int)n, NULL)
            && PQsendQueryPrepared(p->c, name, (int)n, vals, NULL, NULL, 0);
    } else {
        ok = PQsendQueryParams(p->c, text, (int)n, NULL, vals, NULL, NULL, 0);
        if (ok) chunked(p);
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
   which no limit reaches. Rows are charged one at a time as chunked-rows
   mode delivers them, so the rows held are bounded by the limit too. The row
   array doubles as rows arrive and is copied to its exact size once
   complete; that growth's slack, at most two words per row (the old and
   the new array at a doubling or at the copy), is not charged. This bounds
   what the pool builds, not libpq's buffers: libpq copies a chunk's rows,
   up to EKK_CHUNK_ROWS DataRows of any size, into its PGresult before the
   pool sees them, and holds each whole protocol message in its input
   buffer, which keeps the largest such message's size until the session
   is closed; nor the allocator's own overhead. */

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

/* An array of the first `n` slots of `a` (exclusive) with capacity `cap`;
   `a` is freed, its elements moved. */
static lean_object *moved(lean_object *a, size_t n, size_t cap) {
    lean_object *r = lean_alloc_array(n, cap);
    memcpy(lean_array_cptr(r), lean_array_cptr(a), n * sizeof(lean_object *));
    lean_to_array(a)->m_size = 0; /* free only the array */
    lean_dec(a);
    return r;
}

/* Appends `row` to b's rows, doubling the array when it is full. */
static void rows_push(ekk_rows *b, lean_object *row) {
    size_t n = lean_array_size(b->rows);
    if (n == lean_array_capacity(b->rows)) b->rows = moved(b->rows, n, n ? 2 * n : 8);
    lean_array_cptr(b->rows)[n] = row;
    lean_to_array(b->rows)->m_size = n + 1;
}

/* Adds r's rows to `b`, and its column names when `b` has none yet,
   charging each before it is built: 0, with nothing of the row that
   crossed it built, once `b` would cost more than `limit` bytes (less than
   SIZE_MAX). */
static int rows_take(ekk_rows *b, PGresult *r, size_t limit) {
    int nf = PQnfields(r), nt = PQntuples(r);
    if (b->cols == NULL) {
        /* The Result, the column array and names, the row array's header;
           each row adds its slot in the row array. */
        if (!charge(&b->cost, object_cost(sizeof(lean_ctor_object), 2), limit)
            || !charge(&b->cost, object_cost(sizeof(lean_array_object), (size_t)nf), limit)
            || !charge(&b->cost, object_cost(sizeof(lean_array_object), 0), limit))
            return 0;
        for (int f = 0; f < nf; f++) {
            const char *name = PQfname(r, f);
            size_t n = strnlen(name, limit + 1);
            if (n > limit || !charge_text(&b->cost, name, n, limit)) return 0;
        }
        b->cols = lean_alloc_array(0, nf);
        for (int f = 0; f < nf; f++) b->cols = lean_array_push(b->cols, lean_mk_string(PQfname(r, f)));
        b->rows = lean_alloc_array(0, 0);
    }
    size_t row = sizeof(void *) + object_cost(sizeof(lean_array_object), (size_t)nf);
    size_t some = object_cost(sizeof(lean_ctor_object), 1);
    for (int t = 0; t < nt; t++) {
        if (!charge(&b->cost, row, limit)) return 0;
        for (int f = 0; f < nf; f++) {
            if (PQgetisnull(r, t, f)) continue;
            if (!charge(&b->cost, some, limit)
                || !charge_text(&b->cost, PQgetvalue(r, t, f), (size_t)PQgetlength(r, t, f), limit))
                return 0;
        }
        lean_object *o = lean_alloc_array(0, nf);
        for (int f = 0; f < nf; f++) {
            lean_object *v;
            if (PQgetisnull(r, t, f)) v = lean_box(0);
            else {
                v = lean_alloc_ctor(1, 1, 0);
                /* Validates the UTF-8 (invalid bytes become U+FFFD). */
                lean_ctor_set(v, 0, lean_mk_string_from_bytes(PQgetvalue(r, t, f), (size_t)PQgetlength(r, t, f)));
            }
            o = lean_array_push(o, v);
        }
        rows_push(b, o);
    }
    return 1;
}

static void rows_drop(ekk_rows *b) {
    if (b->cols) lean_dec(b->cols);
    if (b->rows) lean_dec(b->rows);
    *b = (ekk_rows){0};
}

/* `b`, which rows_take has described, as Result.rows; `b` is left empty.
   The row array is copied to its exact size, as charged. */
static lean_object *rows_finish(ekk_rows *b) {
    lean_object *rows = b->rows;
    size_t n = lean_array_size(rows);
    if (lean_array_capacity(rows) != n) rows = moved(rows, n, n);
    lean_object *res = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(res, 0, b->cols);
    lean_ctor_set(res, 1, rows);
    *b = (ekk_rows){0};
    return res;
}

/* Forgets cache entry k, keeping the others in order. */
static void forget(ekk_pg *p, int k) {
    free(p->sql[k]);
    p->prepared--;
    memmove(p->sql + k, p->sql + k + 1, (size_t)(p->prepared - k) * sizeof p->sql[0]);
    memmove(p->name + k, p->name + k + 1, (size_t)(p->prepared - k) * sizeof p->name[0]);
}

/* Whether an execution of a cached statement that failed with result `r`
   forgets the statement: SQLSTATE 0A000 (feature_not_supported) or 26000
   (invalid_sql_statement_name). These classes hold every error of a
   statement the server can no longer run as prepared (PostgreSQL's
   "cached plan must not change result type" after a schema change is
   0A000; a statement the server no longer has is 26000) and others too:
   PostgreSQL documents no code or field that singles the stale statement
   out (decided 2026-11-17, item 7mzw77). Forgetting a statement that was
   still good costs only its Close and a fresh Prepare under a new name. */
static int evicts(PGresult *r) {
    const char *st = PQresultErrorField(r, PG_DIAG_SQLSTATE);
    return st != NULL && (strcmp(st, "0A000") == 0 || strcmp(st, "26000") == 0);
}

/* Queues the Close of the statement the query in flight forgot, with a
   Sync of its own, once the query's Sync has arrived: 2 (flush, then wait
   for its results), or -1 when the connection failed. Closing a statement
   the server does not have is not an error (protocol, "Extended Query"),
   so a 26000's statement is closed the same way. */
static int close_evicted(ekk_pg *p) {
    char name[32];
    stmt_name(name, p->evicted_name);
    p->evicted = 0;
    p->stage = EKK_CLOSING;
    return PQsendClosePrepared(p->c, name) && PQpipelineSync(p->c) ? 2 : -1;
}

static lean_object *error_of(PGresult *r) {
    const char *st = PQresultErrorField(r, PG_DIAG_SQLSTATE);
    return ekk_pg_error(st ? st : "XX000", PQresultErrorMessage(r));
}

/* The message of the answer to a result that crossed Query.maxResultBytes
   (Result.abandoned): the session is closed before the statement's end, so
   whether it took effect is unknown. */
#define EKK_TOO_BIG "the result exceeds Query.maxResultBytes; the session was closed before the statement ended, so whether it took effect is unknown"

/* Collects the results that have arrived, without blocking, until the
   query's Sync. *acc holds the query's Result: its execution's rows,
   gathered chunk by chunk (chunked-rows mode) and complete at the zero-row
   result that ends them, or its error (an error after some rows discards
   them), or the error of preparing its statement (which is then forgotten,
   and the execution PostgreSQL skipped is ignored). A cached statement
   whose execution fails with an error that `evicts` it is forgotten and,
   after the query's Sync, closed on the server (close_evicted). 1 when the
   Sync arrived (*acc is complete), and the Close's Sync after it when one
   was sent; 0 when more input is needed; 2 when collect queued the Close:
   flush it (ekk_pg_flush), then more input is needed; -1 when the session
   must be closed, with *acc the query's result: Result.abandoned 08006
   when the connection failed (ekk_pg_lost_sent), an error when the statement started COPY, which this pool does not
   speak, or it left a transaction open; Result.abandoned 54000
   (EKK_TOO_BIG) when its rows crossed Query.maxResultBytes (the rows
   gathered are released, the rest is never read); the query's own error
   when the Close failed or the connection failed after the query's
   Sync. */
int ekk_pg_collect(ekk_pg *p, lean_object **acc) {
    while (!PQisBusy(p->c)) {
        PGresult *r = PQgetResult(p->c);
        if (r == NULL) {
            /* A NULL ends one command's results; two in a row mean nothing is
               pending, so the Sync can never come. */
            if (p->last_null || PQstatus(p->c) != CONNECTION_OK) {
                /* After the query's Sync its answer is known. */
                if (p->stage == EKK_CLOSING || p->stage == EKK_CLOSED) return -1;
                if (*acc) lean_dec(*acc);
                *acc = ekk_pg_lost_sent(p);
                return -1;
            }
            p->last_null = 1;
            if (p->stage == EKK_PREPARED) {
                /* The execution is libpq's queue head now, and the next
                   PQisBusy would parse its first result: its mode is set
                   before its results are retrieved, as libpq documents
                   for pipeline mode (above, EKK_STATEMENTS). */
                chunked(p);
                p->stage = EKK_EXECUTING;
            }
            continue;
        }
        p->last_null = 0;
        ExecStatusType st = PQresultStatus(r);
        if (p->stage == EKK_CLOSING || p->stage == EKK_CLOSED) {
            /* The Close's CommandComplete, then its Sync; anything else ends
               the session, the query's answer kept. */
            PQclear(r);
            if (st == PGRES_COMMAND_OK && p->stage == EKK_CLOSING) { p->stage = EKK_CLOSED; continue; }
            return st == PGRES_PIPELINE_SYNC && p->stage == EKK_CLOSED && PQtransactionStatus(p->c) == PQTRANS_IDLE ? 1 : -1;
        }
        lean_object *v = NULL;
        int stop = 0;
        switch (st) {
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
            return p->evicted ? close_evicted(p) : 1;
        case PGRES_PIPELINE_ABORTED:
            break; /* skipped after the error already in *acc */
        case PGRES_COMMAND_OK:
            if (p->stage == EKK_PREPARING) { p->stage = EKK_PREPARED; break; } /* the statement is prepared */
            /* fall through: a statement without rows */
        case PGRES_TUPLES_OK:
        case PGRES_EMPTY_QUERY:
        case PGRES_TUPLES_CHUNK:
            if (!rows_take(&p->rows, r, p->limit)) {
                PQclear(r);
                rows_drop(&p->rows);
                if (*acc) lean_dec(*acc);
                *acc = ekk_pg_abandoned("54000", EKK_TOO_BIG);
                return -1;
            }
            /* A chunk is followed by more, or by the zero-row
               PGRES_TUPLES_OK that ends them (or an error). */
            if (st != PGRES_TUPLES_CHUNK) v = rows_finish(&p->rows);
            break;
        case PGRES_COPY_IN:
        case PGRES_COPY_OUT:
        case PGRES_COPY_BOTH:
            v = ekk_pg_error("0A000", "COPY is not supported");
            stop = 1;
            break;
        default:
            if (p->stage == EKK_PREPARING) {
                /* Preparing failed: forget the statement, which the server
                   does not hold. */
                p->stage = EKK_SKIPPED;
                forget(p, p->prepared - 1);
            } else if (p->cached >= 0 && evicts(r)) {
                p->evicted = 1;
                p->evicted_name = p->name[p->cached];
                forget(p, p->cached);
                p->cached = -1;
            }
            rows_drop(&p->rows); /* rows before the error are not the answer */
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
