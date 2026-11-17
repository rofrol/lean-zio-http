/* Deterministic tests of pg.c against the real libpq (`zig build test`;
   README, "PostgreSQL"): a fake PostgreSQL server on a Unix socket in a
   temporary directory, driven step by step from this one thread, answers
   each query with a fixed sequence of backend messages, delivered whole, one
   message at a time, or one byte at a time. After every piece the test does
   what pg.zig does when the socket is readable, ekk_pg_consume then
   ekk_pg_collect, and checks that the query completes exactly at the
   piece that ends its reply, with the expected result, and that the rows it
   holds are exactly the DataRows of the running execution received so far
   (single-row mode). It includes pg.c to see its session's fields
   (last_null, prepared, rows, limit), and counts its
   PQgetResult calls: a collect that keeps getting results (a reply it
   misreads, such as COPY when it does not stop) fails the test instead of
   looping.

   The fake speaks only what these cases need: protocol 3.0, trust
   authentication, the extended-query messages libpq sends for pg.c's
   pipelines; it reads the client's messages up to the Sync and checks their
   types. */
#define _GNU_SOURCE /* dladdr, on glibc */
#include <dlfcn.h>
#include <libpq-fe.h>
#include <stdio.h>
#include <stdlib.h>

/* PQgetResult calls left to the running ekk_pg_collect; reply() sets it
   before each. A reply here has at most twelve results, the NULLs between
   commands included. */
static int results_left;

static PGresult *bounded_get_result(PGconn *c) {
    if (results_left-- == 0) {
        fprintf(stderr, "pg_glue_test.c: ekk_pg_collect called PQgetResult more than 32 times in one call\n");
        exit(1);
    }
    return PQgetResult(c);
}

#define PQgetResult bounded_get_result
#include "pg.c"
#undef PQgetResult

/* A whole PGresult's rows as Result.rows, through the same rows_take
   that collect gives each single row, or 54000 when they cost more than
   `limit`. */
static lean_object *rows_within(PGresult *r, size_t limit) {
    ekk_rows b = {0};
    if (!rows_take(&b, r, limit)) {
        rows_drop(&b);
        return ekk_pg_error("54000", "over the limit");
    }
    return rows_finish(&b);
}

static lean_object *rows_of(PGresult *r) { return rows_within(r, EKK_MAX_RESULT_BYTES); }

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* Exported by the Lean runtime but not declared in lean.h. */
void lean_initialize_runtime_module(void);

static const char *current = "";

static void fail(int line, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "pg_glue_test.c:%d: %s: ", line, current);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}
#define CHECK(cond, ...) do { if (!(cond)) fail(__LINE__, __VA_ARGS__); } while (0)

/* ---- backend messages ---- */

typedef struct { uint8_t b[4096]; size_t n; size_t ends[64]; size_t nmsg; } msgs;

static void put8(msgs *m, uint8_t v) { m->b[m->n++] = v; }
static void put16(msgs *m, uint16_t v) { put8(m, v >> 8); put8(m, v & 0xff); }
static void put32(msgs *m, uint32_t v) { put16(m, v >> 16); put16(m, v & 0xffff); }
static void puts0(msgs *m, const char *s) { size_t k = strlen(s) + 1; memcpy(m->b + m->n, s, k); m->n += k; }

/* Starts a message of type t; end() fills in its length. */
static size_t begin(msgs *m, char t) { put8(m, (uint8_t)t); size_t at = m->n; put32(m, 0); return at; }
static void end(msgs *m, size_t at) {
    uint32_t len = (uint32_t)(m->n - at);
    m->b[at] = len >> 24; m->b[at + 1] = len >> 16; m->b[at + 2] = len >> 8; m->b[at + 3] = len;
    m->ends[m->nmsg++] = m->n;
}

static void empty(msgs *m, char t) { end(m, begin(m, t)); }
static void ready(msgs *m, char status) { size_t a = begin(m, 'Z'); put8(m, (uint8_t)status); end(m, a); }
static void complete(msgs *m, const char *tag) { size_t a = begin(m, 'C'); puts0(m, tag); end(m, a); }
static void rowdesc(msgs *m, const char *col) {
    size_t a = begin(m, 'T');
    put16(m, 1); puts0(m, col);
    put32(m, 0); put16(m, 0); put32(m, 25 /* text */); put16(m, (uint16_t)-1); put32(m, (uint32_t)-1); put16(m, 0);
    end(m, a);
}
static void datarow(msgs *m, const char *v) {
    size_t a = begin(m, 'D'); put16(m, 1); put32(m, (uint32_t)strlen(v)); memcpy(m->b + m->n, v, strlen(v)); m->n += strlen(v); end(m, a);
}
/* A DataRow of one field: `n` bytes 'v'. */
static void datarow_n(msgs *m, size_t n) {
    size_t a = begin(m, 'D'); put16(m, 1); put32(m, (uint32_t)n); memset(m->b + m->n, 'v', n); m->n += n; end(m, a);
}
/* An ErrorResponse; `routine` (field R, the server function that raised
   it) is left out when NULL. */
static void errresp_at(msgs *m, const char *sqlstate, const char *message, const char *routine) {
    size_t a = begin(m, 'E');
    put8(m, 'S'); puts0(m, "ERROR"); put8(m, 'V'); puts0(m, "ERROR");
    put8(m, 'C'); puts0(m, sqlstate); put8(m, 'M'); puts0(m, message);
    if (routine) { put8(m, 'R'); puts0(m, routine); }
    put8(m, 0);
    end(m, a);
}
static void errresp(msgs *m, const char *sqlstate, const char *message) { errresp_at(m, sqlstate, message, NULL); }
static void copy(msgs *m, char t) { size_t a = begin(m, t); put8(m, 0); put16(m, 1); put16(m, 0); end(m, a); }

/* ---- the fake server ---- */

typedef struct { char dir[64]; char path[128]; int listener; int conn; } fake;

static void fake_open(fake *f) {
    strcpy(f->dir, "/tmp/pgfakeXXXXXX");
    CHECK(mkdtemp(f->dir) != NULL, "mkdtemp: %s", strerror(errno));
    snprintf(f->path, sizeof f->path, "%s/.s.PGSQL.5432", f->dir);
    struct sockaddr_un a = {0};
    a.sun_family = AF_UNIX;
    strcpy(a.sun_path, f->path);
    f->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(f->listener >= 0 && bind(f->listener, (struct sockaddr *)&a, sizeof a) == 0 && listen(f->listener, 4) == 0,
          "listen on %s: %s", f->path, strerror(errno));
    fcntl(f->listener, F_SETFL, O_NONBLOCK);
    f->conn = -1;
}

static void fake_close(fake *f) {
    close(f->listener);
    unlink(f->path);
    rmdir(f->dir);
}

/* Reads what the client has sent, without waiting. */
static size_t take_input(fake *f, uint8_t *buf, size_t cap) {
    size_t n = 0;
    for (;;) {
        ssize_t k = read(f->conn, buf + n, cap - n);
        if (k <= 0) break;
        n += (size_t)k;
    }
    return n;
}

/* Connects a session to the fake: pg.zig's connect steps, with the fake's
   steps in between. The fake accepts, reads the startup packet (protocol
   3.0) and answers AuthenticationOk, the parameters, BackendKeyData and
   ReadyForQuery. */
static ekk_pg *connect_fake(fake *f) {
    char conninfo[256];
    snprintf(conninfo, sizeof conninfo, "host=%s port=5432 user=fake dbname=fake sslmode=disable gssencmode=disable", f->dir);
    ekk_pg *p = ekk_pg_start(conninfo);
    CHECK(p != NULL, "ekk_pg_start");
    uint8_t in[1024];
    size_t got = 0;
    int answered = 0;
    for (int step = 0; step < 20; step++) {
        int rc = ekk_pg_connect_poll(p);
        if (rc == 3) {
            CHECK(answered, "connected before the fake answered");
            return p;
        }
        CHECK(rc == 1 || rc == 2, "connect failed: %s", PQerrorMessage(p->c));
        if (f->conn < 0) {
            f->conn = accept(f->listener, NULL, NULL);
            if (f->conn < 0) continue;
            fcntl(f->conn, F_SETFL, O_NONBLOCK);
        }
        if (answered) continue;
        got += take_input(f, in + got, sizeof in - got);
        if (got < 8) continue;
        uint32_t len = (uint32_t)in[0] << 24 | in[1] << 16 | in[2] << 8 | in[3];
        if (got < len) continue;
        uint32_t version = (uint32_t)in[4] << 24 | in[5] << 16 | in[6] << 8 | in[7];
        CHECK(version == 196608, "startup asks for protocol %u.%u, the fake speaks 3.0", version >> 16, version & 0xffff);
        msgs m = {0};
        size_t a = begin(&m, 'R'); put32(&m, 0); end(&m, a);
        const char *params[][2] = {{"client_encoding", "UTF8"}, {"server_version", "18.0"},
                                   {"standard_conforming_strings", "on"}, {"integer_datetimes", "on"},
                                   {"DateStyle", "ISO, MDY"}};
        for (size_t i = 0; i < sizeof params / sizeof params[0]; i++) {
            a = begin(&m, 'S'); puts0(&m, params[i][0]); puts0(&m, params[i][1]); end(&m, a);
        }
        a = begin(&m, 'K'); put32(&m, 4242); put32(&m, 77); end(&m, a);
        ready(&m, 'I');
        CHECK(write(f->conn, m.b, m.n) == (ssize_t)m.n, "fake write");
        answered = 1;
    }
    fail(__LINE__, "not connected after 20 steps");
    return NULL;
}

/* Ends the session (pg.zig's teardown) and checks that the fake sees the
   connection close, after a Terminate or none. */
static void finish(ekk_pg *p, fake *f) {
    ekk_pg_finish(p);
    fcntl(f->conn, F_SETFL, 0);
    uint8_t buf[256];
    size_t n = 0;
    for (;;) {
        ssize_t k = read(f->conn, buf + n, sizeof buf - n);
        CHECK(k >= 0, "read after finish: %s", strerror(errno));
        if (k == 0) break;
        n += (size_t)k;
    }
    CHECK(n == 0 || (n == 5 && buf[0] == 'X'), "after PQfinish the fake read %zu bytes, first '%c'", n, n ? buf[0] : ' ');
    close(f->conn);
    f->conn = -1;
}

/* ---- queries ---- */

static lean_object *query(const char *sql, const char *param) {
    lean_object *params = lean_mk_empty_array();
    if (param) {
        lean_object *some = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(some, 0, lean_mk_string(param));
        params = lean_array_push(params, some);
    }
    lean_object *q = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(q, 0, lean_mk_string(sql));
    lean_ctor_set(q, 1, params);
    return q;
}

/* Sends a query as pg.zig does and checks the types of the messages the
   fake reads, which end with the Sync. */
static void send_query(ekk_pg *p, fake *f, const char *sql, const char *param, const char *types) {
    lean_object *err = NULL;
    CHECK(ekk_pg_send(p, query(sql, param), &err) == 0, "ekk_pg_send");
    CHECK(ekk_pg_flush(p) == 0, "ekk_pg_flush left output");
    uint8_t in[4096];
    size_t n = take_input(f, in, sizeof in);
    char seen[32];
    size_t k = 0, at = 0;
    while (at + 5 <= n && k + 1 < sizeof seen) {
        seen[k++] = (char)in[at];
        uint32_t len = (uint32_t)in[at + 1] << 24 | in[at + 2] << 16 | in[at + 3] << 8 | in[at + 4];
        at += 1 + len;
    }
    seen[k] = 0;
    CHECK(at == n && strcmp(seen, types) == 0, "the client sent \"%s\" (%zu of %zu bytes parsed), expected \"%s\"", seen, at, n, types);
}

enum piece { WHOLE, MESSAGE, BYTE };
static const char *piece_name[] = {"whole", "per message", "per byte"};

/* Delivers the reply in pieces; after each, consume and collect. Returns
   collect's result after the last piece, which every earlier piece must
   leave at 0. When a piece ends at byte `between` (nonzero), the end of one
   command's results with the next command's not yet arrived, collect must
   have stopped there with last_null set. */
/* The DataRows among the messages that end at or before byte `at` since
   the last RowDescription, CommandComplete or ErrorResponse: the rows of
   the running execution received so far. */
static size_t rows_received(msgs *m, size_t at) {
    size_t n = 0, start = 0;
    for (size_t i = 0; i < m->nmsg && m->ends[i] <= at; i++) {
        char t = (char)m->b[start];
        if (t == 'D') n++;
        else if (t == 'T' || t == 'C' || t == 'E') n = 0;
        start = m->ends[i];
    }
    return n;
}

static size_t rows_held(ekk_pg *p) { return p->rows.rows ? lean_array_size(p->rows.rows) : 0; }

/* While `on`, the column names and first row of a result being collected,
   with a reference of the test's own, taken the first time collect holds a
   row; kept_released checks that pg.c has since released its references. */
static struct { int on; lean_object *cols, *row; } kept;

static void keep(ekk_pg *p) {
    if (!kept.on || kept.row || rows_held(p) == 0) return;
    kept.cols = p->rows.cols;
    kept.row = lean_array_get_core(p->rows.rows, 0);
    lean_inc(kept.cols);
    lean_inc(kept.row);
}

static void kept_released(void) {
    CHECK(kept.row != NULL, "no row was held to check");
    CHECK(lean_is_exclusive(kept.cols) && lean_is_exclusive(kept.row), "the rows gathered were not released");
    lean_dec(kept.cols);
    lean_dec(kept.row);
    kept.on = 0;
    kept.cols = kept.row = NULL;
}

/* Delivers the reply in pieces until collect returns nonzero; after each,
   consume and collect, which must hold the rows received so far (keep()
   takes them). An AF_UNIX write is readable by the peer when write
   returns, so each piece reaches libpq's next read. Returns collect's
   result and sets *at to the bytes delivered. */
static int reply_until(ekk_pg *p, fake *f, msgs *m, enum piece how, lean_object **acc, size_t between, size_t *at) {
    size_t i = 0;
    *at = 0;
    while (*at < m->n) {
        size_t next = how == WHOLE ? m->n : how == MESSAGE ? m->ends[i++] : *at + 1;
        CHECK(write(f->conn, m->b + *at, next - *at) == (ssize_t)(next - *at), "fake write");
        *at = next;
        CHECK(ekk_pg_consume(p) == 1, "ekk_pg_consume failed after byte %zu: %s", *at, PQerrorMessage(p->c));
        results_left = 32;
        int rc = ekk_pg_collect(p, acc);
        if (rc != 0) return rc;
        CHECK(*at != between || p->last_null, "collect did not stop between two commands at byte %zu", *at);
        CHECK(rows_held(p) == rows_received(m, *at), "collect holds %zu rows after byte %zu, %zu received",
              rows_held(p), *at, rows_received(m, *at));
        keep(p);
    }
    return 0;
}

/* reply_until, which must end exactly at the reply's last byte. */
static int reply(ekk_pg *p, fake *f, msgs *m, enum piece how, lean_object **acc, size_t between) {
    size_t at;
    int rc = reply_until(p, f, m, how, acc, between, &at);
    CHECK(rc != 0, "not complete after the reply's %zu bytes", m->n);
    CHECK(at == m->n, "collect returned %d after %zu of %zu bytes", rc, at, m->n);
    return rc;
}

static void expect_error(lean_object *r, const char *sqlstate) {
    CHECK(r != NULL && lean_ptr_tag(r) == 1, "expected error %s, got %s", sqlstate, r ? "rows" : "nothing");
    const char *got = lean_string_cstr(lean_ctor_get(r, 0));
    CHECK(strcmp(got, sqlstate) == 0, "expected error %s, got %s: %s", sqlstate, got, lean_string_cstr(lean_ctor_get(r, 1)));
    lean_dec(r);
}

/* Rows: the column names joined by ',' and the first row's values. */
static void expect_rows(lean_object *r, const char *col, const char *value) {
    CHECK(r != NULL && lean_ptr_tag(r) == 0, "expected rows, got %s",
          r ? lean_string_cstr(lean_ctor_get(r, 0)) : "nothing");
    lean_object *cols = lean_ctor_get(r, 0), *rows = lean_ctor_get(r, 1);
    if (col == NULL) {
        CHECK(lean_array_size(cols) == 0 && lean_array_size(rows) == 0, "expected no columns and no rows");
    } else {
        CHECK(lean_array_size(cols) == 1 && strcmp(lean_string_cstr(lean_array_get_core(cols, 0)), col) == 0, "column");
        CHECK(lean_array_size(rows) == 1, "%zu rows", lean_array_size(rows));
        lean_object *v = lean_array_get_core(lean_array_get_core(rows, 0), 0);
        CHECK(!lean_is_scalar(v) && strcmp(lean_string_cstr(lean_ctor_get(v, 0)), value) == 0, "value");
    }
    lean_dec(r);
}

/* ---- cases ---- */

#define SQL_A "SELECT $1::int AS x"
#define SQL_B "SELEC 1"

/* Queries that leave the session usable, one after another on one session:
   first use (prepare, execute), prepared use, an execution error, a prepare
   error (the statement is forgotten), and preparing that text again. */
static void usable_session(enum piece how) {
    fake f;
    fake_open(&f);
    ekk_pg *p = connect_fake(&f);
    lean_object *acc;
    msgs m;

    current = "first use: prepare and execute";
    send_query(p, &f, SQL_A, "42", "PBDES");
    m = (msgs){0};
    empty(&m, '1'); empty(&m, '2'); rowdesc(&m, "x"); datarow(&m, "42"); complete(&m, "SELECT 1"); ready(&m, 'I');
    acc = NULL;
    /* Per message and per byte, a piece ends with the ParseComplete: collect
       has the Prepare's result and its NULL and waits for the execution's. */
    CHECK(reply(p, &f, &m, how, &acc, m.ends[0]) == 1, "not complete");
    expect_rows(acc, "x", "42");
    CHECK(p->prepared == 1, "prepared %d", p->prepared);

    current = "prepared use";
    send_query(p, &f, SQL_A, "42", "BDES");
    m = (msgs){0};
    empty(&m, '2'); rowdesc(&m, "x"); datarow(&m, "42"); complete(&m, "SELECT 1"); ready(&m, 'I');
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_rows(acc, "x", "42");

    current = "execution error";
    send_query(p, &f, SQL_A, "0", "BDES");
    m = (msgs){0};
    empty(&m, '2'); rowdesc(&m, "x"); errresp(&m, "22012", "division by zero"); ready(&m, 'I');
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_error(acc, "22012");

    current = "prepare error, execution aborted";
    send_query(p, &f, SQL_B, NULL, "PBDES");
    m = (msgs){0};
    errresp(&m, "42601", "syntax error"); ready(&m, 'I');
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_error(acc, "42601");
    CHECK(p->prepared == 1, "the failed statement is still listed: prepared %d", p->prepared);

    current = "the failed text prepared again, no rows";
    send_query(p, &f, SQL_B, NULL, "PBDES");
    m = (msgs){0};
    empty(&m, '1'); empty(&m, '2'); empty(&m, 'n'); complete(&m, "UPDATE 0"); ready(&m, 'I');
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_rows(acc, NULL, NULL);
    CHECK(p->prepared == 2, "prepared %d", p->prepared);

    current = "finish";
    finish(p, &f);
    fake_close(&f);
}

#define SQL_C "SELECT 2 AS y"
#define STALE_PLAN "cached plan must not change result type"

/* `sql` (with no parameter) prepared and executed on its first use,
   answered with one row of column `col`; checks its new statement name. */
static void prepare_ok(ekk_pg *p, fake *f, enum piece how, const char *sql, const char *col, unsigned long long name) {
    send_query(p, f, sql, NULL, "PBDES");
    msgs m = {0};
    empty(&m, '1'); empty(&m, '2'); rowdesc(&m, col); datarow(&m, "1"); complete(&m, "SELECT 1"); ready(&m, 'I');
    lean_object *acc = NULL;
    CHECK(reply(p, f, &m, how, &acc, 0) == 1, "not complete");
    expect_rows(acc, col, "1");
    CHECK(p->prepared > 0 && strcmp(p->sql[p->prepared - 1], sql) == 0 && p->name[p->prepared - 1] == name,
          "the new entry is not \"%s\" as ekk%llu", sql, name);
}

/* The cached `sql` executed and failing with `sqlstate` raised by
   `routine`, the session left in transaction status `status`; returns
   collect's result and checks the error. */
static int cached_fails(ekk_pg *p, fake *f, enum piece how, const char *sql, const char *sqlstate,
                        const char *routine, char status, const char *expected) {
    send_query(p, f, sql, NULL, "BDES");
    msgs m = {0};
    errresp_at(&m, sqlstate, STALE_PLAN, routine); ready(&m, status);
    lean_object *acc = NULL;
    int rc = reply(p, f, &m, how, &acc, 0);
    expect_error(acc, expected);
    return rc;
}

/* Cached statements that go stale (pg.c, `invalidated`): the failing
   query gets the error, the entry is forgotten and its text prepared again
   under a name never used before; other errors keep the entry. */
static void stale_statements(enum piece how) {
    fake f;
    fake_open(&f);
    ekk_pg *p = connect_fake(&f);

    current = "stale: prepared";
    prepare_ok(p, &f, how, SQL_A, "x", 0);

    current = "stale: a schema change altered the result type";
    CHECK(cached_fails(p, &f, how, SQL_A, "0A000", "RevalidateCachedQuery", 'I', "0A000") == 1, "the session was ended");
    CHECK(p->prepared == 0 && p->stale == 1, "prepared %d, stale %d", p->prepared, p->stale);

    current = "stale: prepared again under a new name";
    prepare_ok(p, &f, how, SQL_A, "x", 1);

    current = "stale: another 0A000 keeps the statement";
    CHECK(cached_fails(p, &f, how, SQL_A, "0A000", "transformStmt", 'I', "0A000") == 1, "the session was ended");
    CHECK(cached_fails(p, &f, how, SQL_A, "0A000", NULL, 'I', "0A000") == 1, "the session was ended");
    CHECK(p->prepared == 1 && p->stale == 1, "prepared %d, stale %d", p->prepared, p->stale);

    current = "stale: the statement no longer on the server (26000)";
    CHECK(cached_fails(p, &f, how, SQL_A, "26000", "FetchPreparedStatement", 'I', "26000") == 1, "the session was ended");
    CHECK(p->prepared == 0 && p->stale == 2, "prepared %d, stale %d", p->prepared, p->stale);

    current = "stale: the first of two entries forgotten";
    prepare_ok(p, &f, how, SQL_A, "x", 2);
    prepare_ok(p, &f, how, SQL_C, "y", 3);
    CHECK(cached_fails(p, &f, how, SQL_A, "0A000", "RevalidateCachedQuery", 'I', "0A000") == 1, "the session was ended");
    CHECK(p->prepared == 1 && strcmp(p->sql[0], SQL_C) == 0 && p->name[0] == 3, "the remaining entry moved wrongly");

    current = "stale: an execution right after its Prepare is not a cached one";
    send_query(p, &f, SQL_B, NULL, "PBDES");
    msgs m = {0};
    empty(&m, '1'); errresp_at(&m, "0A000", STALE_PLAN, "RevalidateCachedQuery"); ready(&m, 'I');
    lean_object *acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_error(acc, "0A000");
    CHECK(p->prepared == 2 && strcmp(p->sql[1], SQL_B) == 0 && p->stale == 3, "prepared %d, stale %d", p->prepared, p->stale);

    current = "stale: the remaining entry still executed by name";
    send_query(p, &f, SQL_C, NULL, "BDES");
    m = (msgs){0};
    empty(&m, '2'); rowdesc(&m, "y"); datarow(&m, "2"); complete(&m, "SELECT 1"); ready(&m, 'I');
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_rows(acc, "y", "2");

    current = "stale: in a failed transaction the session is still closed";
    CHECK(cached_fails(p, &f, how, SQL_C, "0A000", "RevalidateCachedQuery", 'E', "25000") == -1, "the session was kept");
    CHECK(p->prepared == 1 && strcmp(p->sql[0], SQL_B) == 0, "prepared %d", p->prepared);
    finish(p, &f);
    fake_close(&f);
}

/* A session closes, after the failing query's result, once EKK_STATEMENTS
   forgotten statements may remain on the server. */
static void stale_bound(enum piece how) {
    current = "stale bound";
    fake f;
    fake_open(&f);
    ekk_pg *p = connect_fake(&f);
    for (int i = 0; i < EKK_STATEMENTS; i++) {
        prepare_ok(p, &f, how, SQL_C, "y", (unsigned long long)i);
        int rc = cached_fails(p, &f, how, SQL_C, "0A000", "RevalidateCachedQuery", 'I', "0A000");
        CHECK(rc == (i + 1 < EKK_STATEMENTS ? 1 : -1), "after %d stale statements collect returned %d", i + 1, rc);
    }
    finish(p, &f);
    fake_close(&f);
}

/* A query whose reply ends the session: collect returns -1 with `sqlstate`
   at the reply's last byte, then the session is finished. */
static void ending(enum piece how, const char *name, const char *sql, char last, const char *sqlstate) {
    current = name;
    fake f;
    fake_open(&f);
    ekk_pg *p = connect_fake(&f);
    send_query(p, &f, sql, NULL, "PBDES");
    msgs m = {0};
    empty(&m, '1'); empty(&m, '2'); empty(&m, 'n');
    if (last == 'T') {
        complete(&m, "BEGIN");
        ready(&m, 'T');
    } else {
        copy(&m, last);
    }
    lean_object *acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == -1, "the session was not ended");
    expect_error(acc, sqlstate);
    finish(p, &f);
    fake_close(&f);
}

/* The server's connection ends in the middle of a reply: the query fails
   with 08006, through consume (pg.zig's `lost`) or collect. */
static void cut(enum piece how) {
    current = "connection lost mid-reply";
    fake f;
    fake_open(&f);
    ekk_pg *p = connect_fake(&f);
    send_query(p, &f, SQL_A, "42", "PBDES");
    msgs m = {0};
    empty(&m, '1'); empty(&m, '2'); rowdesc(&m, "x");
    lean_object *acc = NULL;
    /* All but the RowDescription's last byte, then EOF. */
    m.n--; m.ends[m.nmsg - 1]--;
    size_t at;
    CHECK(reply_until(p, &f, &m, how, &acc, 0, &at) == 0, "complete without a Sync");
    close(f.conn);
    f.conn = -1;
    if (ekk_pg_consume(p) == 1) {
        CHECK(ekk_pg_collect(p, &acc) == -1, "a lost connection not reported");
        expect_error(acc, "08006");
    } else if (acc) {
        lean_dec(acc);
    }
    ekk_pg_finish(p);
    fake_close(&f);
}

/* ---- what a result costs (pg.c, result_fits) ----
   Results made with libpq's own PGresult builders, no server needed. */

/* A PGresult of `nf` (at most 4) text columns named `cols` and `nt` rows whose field (t, f) is value(t, f, &len): NULL for
   SQL NULL. */
typedef const char *(*value_fn)(int t, int f, int *len);
/* Rows t0 .. t0 + nt - 1 of value(t, f, &len). */
static PGresult *made_from(int nf, const char *const *cols, int t0, int nt, value_fn value) {
    PGresult *r = PQmakeEmptyPGresult(NULL, PGRES_TUPLES_OK);
    CHECK(r != NULL, "PQmakeEmptyPGresult");
    PGresAttDesc d[4] = {0};
    for (int f = 0; f < nf; f++) {
        d[f].name = (char *)cols[f];
        d[f].typid = 25;
        d[f].typlen = -1;
        d[f].atttypmod = -1;
    }
    CHECK(PQsetResultAttrs(r, nf, d), "PQsetResultAttrs");
    for (int t = 0; t < nt; t++)
        for (int f = 0; f < nf; f++) {
            int len = -1;
            const char *v = value(t0 + t, f, &len);
            CHECK(PQsetvalue(r, t, f, (char *)v, v ? len : -1), "PQsetvalue");
        }
    return r;
}

static PGresult *made(int nf, const char *const *cols, int nt, value_fn value) { return made_from(nf, cols, 0, nt, value); }

/* The rows of value(t, f) for t < nt as single-row mode delivers them, one
   PGresult each, then the zero-row result, gathered as collect does. */
static lean_object *rows_by_row(int nf, const char *const *cols, int nt, value_fn value, size_t limit) {
    ekk_rows b = {0};
    for (int t = 0; t <= nt; t++) {
        PGresult *r = made_from(nf, cols, t, t < nt ? 1 : 0, value);
        int ok = rows_take(&b, r, limit);
        PQclear(r);
        if (!ok) {
            rows_drop(&b);
            return ekk_pg_error("54000", "over the limit");
        }
    }
    return rows_finish(&b);
}

/* What the Lean value rows_of built costs by the same measure as
   result_fits, from the sizes its objects have (capacities included). */
static size_t built_cost(lean_object *res) {
    size_t total = object_cost(sizeof(lean_ctor_object), 2);
    lean_object *cols = lean_ctor_get(res, 0), *rows = lean_ctor_get(res, 1);
    total += object_cost(sizeof(lean_array_object), lean_array_capacity(cols));
    for (size_t f = 0; f < lean_array_size(cols); f++)
        total += object_cost(lean_string_byte_size(lean_array_get_core(cols, f)), 0);
    total += object_cost(sizeof(lean_array_object), lean_array_capacity(rows));
    for (size_t t = 0; t < lean_array_size(rows); t++) {
        lean_object *row = lean_array_get_core(rows, t);
        total += object_cost(sizeof(lean_array_object), lean_array_capacity(row));
        for (size_t f = 0; f < lean_array_size(row); f++) {
            lean_object *v = lean_array_get_core(row, f);
            if (lean_is_scalar(v)) continue;
            total += object_cost(sizeof(lean_ctor_object), 1) + object_cost(lean_string_byte_size(lean_ctor_get(v, 0)), 0);
        }
    }
    return total;
}

static const char *null_value(int t, int f, int *len) { (void)t; (void)f; (void)len; return NULL; }
static const char *empty_value(int t, int f, int *len) { (void)t; (void)f; *len = 0; return ""; }
/* Four bytes, each an invalid sequence of its own (no lead byte that
   consumes continuation bytes): four U+FFFD, three bytes each, as
   charged. */
static const char *invalid_value(int t, int f, int *len) { (void)t; (void)f; *len = 4; return "\xff\xfe\xff\xfe"; }

static void expect_rows_count(lean_object *r, size_t n) {
    CHECK(r != NULL && lean_ptr_tag(r) == 0, "expected rows, got %s: %s", r ? lean_string_cstr(lean_ctor_get(r, 0)) : "nothing",
          r ? lean_string_cstr(lean_ctor_get(r, 1)) : "");
    CHECK(lean_array_size(lean_ctor_get(r, 1)) == n, "%zu rows, expected %zu", lean_array_size(lean_ctor_get(r, 1)), n);
    lean_dec(r);
}

/* One of each kind of value, by row: NULL, empty, ASCII, multibyte UTF-8,
   invalid bytes (an overlong form among them), a truncated sequence, and
   valid text around an encoded surrogate. */
static const char *mixed[] = {NULL, "", "hello", "za\xc5\xbc\xc3\xb3\xc5\x82\xc4\x87 \xf0\x9f\x98\x80",
                              "\xff\xfe\xc0\x80", "\xe2\x82", "a\xed\xa0\x80z"};
#define MIXED_ROWS (int)(sizeof mixed / sizeof mixed[0])
static const char *mixed_value(int t, int f, int *len) {
    const char *v = mixed[(t + f) % MIXED_ROWS];
    if (v) *len = (int)strlen(v);
    return v;
}
/* Mixed values 0 to 3 only: valid UTF-8, charged exactly as built. */
static const char *valid_value(int t, int f, int *len) {
    const char *v = mixed[(t + f) % 4];
    if (v) *len = (int)strlen(v);
    return v;
}

/* utf8_valid agrees with the Lean runtime: a string Lean keeps byte for
   byte is valid, one it changes is not. Every sequence of up to two bytes,
   every three-byte one led by a multibyte lead, and four-byte edge cases. */
static int lean_keeps(const unsigned char *s, size_t n) {
    lean_object *o = lean_mk_string_from_bytes((const char *)s, n);
    int same = lean_string_size(o) == n + 1 && memcmp(lean_string_cstr(o), s, n) == 0;
    lean_dec(o);
    return same;
}

static void utf8_agrees(void) {
    current = "utf8_valid agrees with lean_mk_string_from_bytes";
    unsigned char s[4];
    for (unsigned a = 0; a < 256; a++) {
        s[0] = (unsigned char)a;
        CHECK(utf8_valid(s, 1) == lean_keeps(s, 1), "%02x", a);
        for (unsigned b = 0; b < 256; b++) {
            s[1] = (unsigned char)b;
            CHECK(utf8_valid(s, 2) == lean_keeps(s, 2), "%02x %02x", a, b);
            if (a < 0xe0 || a > 0xf7) continue;
            for (unsigned c = 0; c < 256; c++) {
                s[2] = (unsigned char)c;
                CHECK(utf8_valid(s, 3) == lean_keeps(s, 3), "%02x %02x %02x", a, b, c);
            }
        }
    }
    const char *four[] = {"\xf0\x9f\x98\x80", "\xf0\x8f\xbf\xbf", "\xf4\x8f\xbf\xbf", "\xf4\x90\x80\x80",
                          "\xf5\x80\x80\x80", "\xf0\x9f\x98\x41", "\xf0\x9f\x98"};
    for (size_t i = 0; i < sizeof four / sizeof four[0]; i++) {
        size_t n = strlen(four[i]);
        CHECK(utf8_valid((const unsigned char *)four[i], n) == lean_keeps((const unsigned char *)four[i], n), "four[%zu]", i);
    }
}

/* The charge saturates instead of wrapping. */
static void cost_overflow(void) {
    current = "result cost: overflow";
    size_t t = 0;
    CHECK(charge(&t, 100, 100) && t == 100, "a charge up to the limit refused");
    CHECK(!charge(&t, 1, 100), "a charge past the limit accepted");
    t = 1;
    CHECK(!charge(&t, SIZE_MAX, SIZE_MAX - 1), "a wrapping charge accepted");
    CHECK(object_cost(0, SIZE_MAX) == SIZE_MAX, "words overflow");
    CHECK(object_cost(SIZE_MAX / 8 * 8, 0) == SIZE_MAX, "rounding overflows");
    CHECK(object_cost(sizeof(lean_array_object), SIZE_MAX / 8) == SIZE_MAX, "header overflows");
    CHECK(string_cost(SIZE_MAX / 3 + 1, 0) == SIZE_MAX, "replacement overflows");
    CHECK(string_cost(SIZE_MAX - sizeof(lean_string_object), 1) == SIZE_MAX, "string header overflows");
    CHECK(object_cost(sizeof(lean_array_object), 1) == 40 && string_cost(1, 1) == 48 && string_cost(1, 0) == 48
              && string_cost(4, 0) == 56,
          "an object's cost: header, rounding to 8, one word");
}

/* A result is accepted exactly up to its cost, which is what its Lean value
   costs (more for invalid UTF-8), and refused below it; NULL and empty
   values cost their slots. */
static void cost_bound(void) {
    const char *cols[] = {"a", "column b"};

    current = "result cost: exact bound, valid UTF-8";
    PGresult *r = made(2, cols, 3, mixed_value);
    lean_object *res = rows_within(r, SIZE_MAX - 1);
    CHECK(lean_ptr_tag(res) == 0, "refused without a limit");
    size_t c = built_cost(res);
    lean_dec(res);
    /* Mixed values 0 to 3 (NULL, empty, ASCII, multibyte): all valid, so
       charged as built. */
    expect_rows_count(rows_within(r, c), 3);
    expect_error(rows_within(r, c - 1), "54000");
    PQclear(r);

    current = "result cost: row by row, the same exact bound";
    res = rows_by_row(2, cols, 3, mixed_value, SIZE_MAX - 1);
    CHECK(lean_ptr_tag(res) == 0 && built_cost(res) == c, "row by row costs %zu, whole %zu", built_cost(res), c);
    lean_dec(res);
    expect_rows_count(rows_by_row(2, cols, 3, mixed_value, c), 3);
    expect_error(rows_by_row(2, cols, 3, mixed_value, c - 1), "54000");
    current = "result cost: row by row, many rows copied to their exact size";
    res = rows_by_row(2, cols, 35, valid_value, SIZE_MAX - 1);
    c = built_cost(res);
    CHECK(lean_array_capacity(lean_ctor_get(res, 1)) == 35, "row array capacity %zu",
          lean_array_capacity(lean_ctor_get(res, 1)));
    lean_dec(res);
    expect_rows_count(rows_by_row(2, cols, 35, valid_value, c), 35);
    expect_error(rows_by_row(2, cols, 35, valid_value, c - 1), "54000");

    current = "result cost: invalid UTF-8 charged at least as built";
    r = made(2, cols, 3 * MIXED_ROWS, mixed_value);
    res = rows_within(r, SIZE_MAX - 1);
    c = built_cost(res);
    lean_dec(res);
    expect_error(rows_within(r, c - 1), "54000");
    PQclear(r);

    current = "result cost: each invalid byte replaced, charged as built";
    r = made(1, cols, 1, invalid_value);
    res = rows_within(r, SIZE_MAX - 1);
    c = built_cost(res);
    lean_dec(res);
    expect_rows_count(rows_within(r, c), 1);
    expect_error(rows_within(r, c - 1), "54000");
    PQclear(r);

    /* At Query.maxResultBytes, 22,000 rows of one NULL (40 bytes each and a
       slot of the row array) or of one empty string (also its `some` and
       its string) are over the bound, though they hold no text. */
    current = "result cost: many NULLs over Query.maxResultBytes";
    r = made(1, cols, 22000, null_value);
    expect_error(rows_of(r), "54000");
    PQclear(r);
    current = "result cost: many empty strings over Query.maxResultBytes";
    r = made(1, cols, 22000, empty_value);
    expect_error(rows_of(r), "54000");
    PQclear(r);
    current = "result cost: many NULLs within Query.maxResultBytes";
    r = made(1, cols, 21000, null_value);
    expect_rows_count(rows_of(r), 21000);
    PQclear(r);
}


/* ---- single-row collection (pg.c, ekk_rows) ---- */

/* Rows of one column `col` whose values, joined by ',', are `values`. */
static void expect_values(lean_object *r, const char *col, size_t n, const char *values) {
    CHECK(r != NULL && lean_ptr_tag(r) == 0, "expected rows, got %s: %s", r ? lean_string_cstr(lean_ctor_get(r, 0)) : "nothing",
          r ? lean_string_cstr(lean_ctor_get(r, 1)) : "");
    lean_object *cols = lean_ctor_get(r, 0), *rows = lean_ctor_get(r, 1);
    CHECK(lean_array_size(cols) == 1 && strcmp(lean_string_cstr(lean_array_get_core(cols, 0)), col) == 0, "column");
    CHECK(lean_array_size(rows) == n, "%zu rows, expected %zu", lean_array_size(rows), n);
    char joined[256] = "";
    for (size_t t = 0; t < n; t++) {
        lean_object *v = lean_array_get_core(lean_array_get_core(rows, t), 0);
        CHECK(!lean_is_scalar(v), "row %zu is NULL", t);
        if (t) strcat(joined, ",");
        strncat(joined, lean_string_cstr(lean_ctor_get(v, 0)), sizeof joined - strlen(joined) - 2);
    }
    CHECK(strcmp(joined, values) == 0, "values %s, expected %s", joined, values);
    lean_dec(r);
}

/* A cached SQL_A execution answered with three rows of `len` bytes each. */
static void three_rows(msgs *m, size_t len) {
    *m = (msgs){0};
    empty(m, '2'); rowdesc(m, "x"); datarow_n(m, len); datarow_n(m, len); datarow_n(m, len); complete(m, "SELECT 3"); ready(m, 'I');
}

/* Where the k-th message (from 0) of type t ends. */
static size_t end_of(msgs *m, char t, int k) {
    size_t start = 0;
    for (size_t i = 0; i < m->nmsg; i++) {
        if ((char)m->b[start] == t && k-- == 0) return m->ends[i];
        start = m->ends[i];
    }
    fail(__LINE__, "no message %c", t);
    return 0;
}

/* The query's rows crossed the bound at byte `at` of the reply, which
   ends there: 54000, the rows gathered released, the session to close. */
static void expect_overflow(ekk_pg *p, int rc, lean_object *acc, size_t at, size_t crossed) {
    CHECK(rc == -1, "collect returned %d over the bound", rc);
    CHECK(at == crossed, "the bound ended the reply at byte %zu, not at the row that crossed it (%zu)", at, crossed);
    CHECK(rows_held(p) == 0 && p->rows.cols == NULL, "rows still held after the bound");
    CHECK(strstr(lean_string_cstr(lean_ctor_get(acc, 1)), "unknown") != NULL, "the message does not say the outcome is unknown");
    expect_error(acc, "54000");
}

/* Rows arrive one at a time (reply() checks how many are held after each
   piece) on a first use, a cached and an unnamed execution; zero rows keep
   their columns; rows then an error answer the error; and a result over
   the session's limit closes it at the row that crosses it, a result at
   exactly the limit does not. */
static void rows_and_bound(enum piece how) {
    fake f;
    fake_open(&f);
    ekk_pg *p = connect_fake(&f);
    lean_object *acc;
    msgs m;
    size_t at;

    current = "rows: first use, three rows";
    send_query(p, &f, SQL_A, "1", "PBDES");
    m = (msgs){0};
    empty(&m, '1'); empty(&m, '2'); rowdesc(&m, "x"); datarow(&m, "1"); datarow(&m, "2"); datarow(&m, "3");
    complete(&m, "SELECT 3"); ready(&m, 'I');
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, m.ends[0]) == 1, "not complete");
    expect_values(acc, "x", 3, "1,2,3");

    current = "rows: cached, zero rows keep their columns";
    send_query(p, &f, SQL_A, "1", "BDES");
    m = (msgs){0};
    empty(&m, '2'); rowdesc(&m, "x"); complete(&m, "SELECT 0"); ready(&m, 'I');
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_values(acc, "x", 0, "");

    current = "rows: rows then an error answer the error";
    send_query(p, &f, SQL_A, "1", "BDES");
    m = (msgs){0};
    empty(&m, '2'); rowdesc(&m, "x"); datarow(&m, "1"); datarow(&m, "2"); errresp(&m, "22012", "division by zero"); ready(&m, 'I');
    acc = NULL;
    kept.on = how != WHOLE;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_error(acc, "22012");
    CHECK(rows_held(p) == 0, "rows still held after the error");
    if (how != WHOLE) kept_released();

    current = "rows: the measure of three rows";
    send_query(p, &f, SQL_A, "1", "BDES");
    three_rows(&m, 100);
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    size_t c = built_cost(acc);
    expect_rows_count(acc, 3);

    current = "rows: a result at exactly the limit";
    p->limit = c;
    send_query(p, &f, SQL_A, "1", "BDES");
    three_rows(&m, 100);
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete at the limit");
    expect_rows_count(acc, 3);

    current = "rows: one byte over the limit, cached";
    p->limit = c - 1;
    send_query(p, &f, SQL_A, "1", "BDES");
    three_rows(&m, 100);
    acc = NULL;
    kept.on = how != WHOLE;
    int rc = reply_until(p, &f, &m, how, &acc, 0, &at);
    expect_overflow(p, rc, acc, at, how == WHOLE ? m.n : end_of(&m, 'D', 2));
    if (how != WHOLE) kept_released();
    finish(p, &f);

    current = "rows: a single field over the limit, first use";
    p = connect_fake(&f);
    p->limit = 200;
    send_query(p, &f, SQL_A, "1", "PBDES");
    m = (msgs){0};
    empty(&m, '1'); empty(&m, '2'); rowdesc(&m, "x"); datarow_n(&m, 300); complete(&m, "SELECT 1"); ready(&m, 'I');
    acc = NULL;
    rc = reply_until(p, &f, &m, how, &acc, m.ends[0], &at);
    expect_overflow(p, rc, acc, at, how == WHOLE ? m.n : end_of(&m, 'D', 0));
    finish(p, &f);

    current = "rows: unnamed, past EKK_STATEMENTS cached";
    p = connect_fake(&f);
    for (int i = 0; i < EKK_STATEMENTS; i++) {
        char sql[32];
        snprintf(sql, sizeof sql, "SELECT %d AS y", i);
        prepare_ok(p, &f, how, sql, "y", (unsigned long long)i);
    }
    send_query(p, &f, "SELECT 99 AS x", NULL, "PBDES");
    m = (msgs){0};
    empty(&m, '1'); empty(&m, '2'); rowdesc(&m, "x"); datarow(&m, "7"); datarow(&m, "8"); complete(&m, "SELECT 2"); ready(&m, 'I');
    acc = NULL;
    CHECK(reply(p, &f, &m, how, &acc, 0) == 1, "not complete");
    expect_values(acc, "x", 2, "7,8");
    CHECK(p->prepared == EKK_STATEMENTS, "prepared %d", p->prepared);

    current = "rows: unnamed, over the limit";
    /* The result's own objects and the first row of 100 bytes cost 368, the
       second row 216 more. */
    p->limit = 400;
    send_query(p, &f, "SELECT 98 AS x", NULL, "PBDES");
    m = (msgs){0};
    empty(&m, '1'); empty(&m, '2'); rowdesc(&m, "x"); datarow_n(&m, 100); datarow_n(&m, 100); complete(&m, "SELECT 2"); ready(&m, 'I');
    acc = NULL;
    kept.on = how != WHOLE;
    rc = reply_until(p, &f, &m, how, &acc, 0, &at);
    expect_overflow(p, rc, acc, at, how == WHOLE ? m.n : end_of(&m, 'D', 1));
    if (how != WHOLE) kept_released();
    finish(p, &f);

    current = "rows: the session ends with rows held";
    p = connect_fake(&f);
    send_query(p, &f, SQL_A, "1", "PBDES");
    m = (msgs){0};
    empty(&m, '1'); empty(&m, '2'); rowdesc(&m, "x"); datarow(&m, "1"); datarow(&m, "2");
    CHECK(write(f.conn, m.b, m.n) == (ssize_t)m.n, "fake write");
    CHECK(ekk_pg_consume(p) == 1, "ekk_pg_consume failed: %s", PQerrorMessage(p->c));
    results_left = 32;
    acc = NULL;
    CHECK(ekk_pg_collect(p, &acc) == 0, "complete without its end");
    CHECK(rows_held(p) == 2, "%zu rows held, 2 received", rows_held(p));
    kept.on = 1;
    keep(p);
    finish(p, &f);
    kept_released();
    fake_close(&f);
}

/* The libpq versions the pool accepts (pg.c, libpq_supported). */
static void libpq_versions(void) {
    current = "libpq versions";
    int no[] = {130020, 140000, 140005, 150000}, yes[] = {140006, 140019, 150001, 160000, 170000, 180006};
    for (size_t i = 0; i < sizeof no / sizeof no[0]; i++) CHECK(!libpq_supported(no[i]), "%d accepted", no[i]);
    for (size_t i = 0; i < sizeof yes / sizeof yes[0]; i++) CHECK(libpq_supported(yes[i]), "%d refused", yes[i]);
    CHECK(ekk_pg_libpq_supported(), "the libpq this test links (%d) is refused", PQlibVersion());
    /* Which libpq the process loaded, for libpq-lines.sh (and the log of
       check.sh): the file that defines PQlibVersion, and its version. */
    Dl_info d;
    CHECK(dladdr((void *)PQlibVersion, &d) != 0 && d.dli_fname != NULL, "dladdr(PQlibVersion) failed");
    printf("pg_glue_test: libpq %d loaded from %s\n", PQlibVersion(), d.dli_fname);
}

int main(void) {
    lean_initialize_runtime_module();
    libpq_versions();
    utf8_agrees();
    cost_overflow();
    cost_bound();
    printf("pg_glue_test: result cost: ok\n");
    for (enum piece how = WHOLE; how <= BYTE; how++) {
        usable_session(how);
        stale_statements(how);
        stale_bound(how);
        ending(how, "COPY TO STDOUT", "COPY t TO STDOUT", 'H', "0A000");
        ending(how, "COPY FROM STDIN", "COPY t FROM STDIN", 'G', "0A000");
        ending(how, "a transaction left open", "BEGIN", 'T', "25000");
        cut(how);
        rows_and_bound(how);
        printf("pg_glue_test: replies %s: ok\n", piece_name[how]);
    }
    return 0;
}
