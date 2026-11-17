/* Deterministic tests of pg.c against the real libpq (`zig build test`;
   README, "PostgreSQL"): a fake PostgreSQL server on a Unix socket in a
   temporary directory, driven step by step from this one thread, answers
   each query with a fixed sequence of backend messages, delivered whole, one
   message at a time, or one byte at a time. After every piece the test does
   what pg.zig does when the socket is readable, ekk_pg_consume then
   ekk_pg_collect, and checks that the query completes exactly at the
   piece that ends its reply, with the expected result. It includes pg.c to
   see its session's fields (last_null, prepared), and counts its
   PQgetResult calls: a collect that keeps getting results (a reply it
   misreads, such as COPY when it does not stop) fails the test instead of
   looping.

   The fake speaks only what these cases need: protocol 3.0, trust
   authentication, the extended-query messages libpq sends for pg.c's
   pipelines; it reads the client's messages up to the Sync and checks their
   types. */
#include <libpq-fe.h>
#include <stdio.h>
#include <stdlib.h>

/* PQgetResult calls left to the running ekk_pg_collect; reply() sets it
   before each. A reply here has at most seven results, the NULLs between
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
static int reply(ekk_pg *p, fake *f, msgs *m, enum piece how, lean_object **acc, size_t between) {
    size_t at = 0, i = 0;
    while (at < m->n) {
        size_t next = how == WHOLE ? m->n : how == MESSAGE ? m->ends[i++] : at + 1;
        CHECK(write(f->conn, m->b + at, next - at) == (ssize_t)(next - at), "fake write");
        at = next;
        CHECK(ekk_pg_consume(p) == 1, "ekk_pg_consume failed after byte %zu: %s", at, PQerrorMessage(p->c));
        results_left = 32;
        int rc = ekk_pg_collect(p, acc);
        if (at < m->n) {
            CHECK(rc == 0, "collect returned %d after %zu of %zu bytes", rc, at, m->n);
            CHECK(at != between || p->last_null, "collect did not stop between two commands at byte %zu", at);
        } else {
            return rc;
        }
    }
    fail(__LINE__, "empty reply");
    return 0;
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
    CHECK(reply(p, &f, &m, how, &acc, 0) == 0, "complete without a Sync");
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

int main(void) {
    lean_initialize_runtime_module();
    for (enum piece how = WHOLE; how <= BYTE; how++) {
        usable_session(how);
        stale_statements(how);
        stale_bound(how);
        ending(how, "COPY TO STDOUT", "COPY t TO STDOUT", 'H', "0A000");
        ending(how, "COPY FROM STDIN", "COPY t FROM STDIN", 'G', "0A000");
        ending(how, "a transaction left open", "BEGIN", 'T', "25000");
        cut(how);
        printf("pg_glue_test: replies %s: ok\n", piece_name[how]);
    }
    return 0;
}
