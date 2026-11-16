#include <lean/lean.h>
#include <string.h>
#include <time.h>

/* Exported by libleanrt (C linkage) but not declared in lean.h of this toolchain. */
void lean_initialize_thread(void);
void lean_finalize_thread(void);

/* Exported from lean/Conn.lean; each takes ownership of its object arguments
   and returns a fresh (State × Action) pair. */
extern lean_object *ekk_conn_open(uint8_t unit);
extern lean_object *ekk_conn_on_recv(uint64_t now, lean_object *state, lean_object *data);
extern lean_object *ekk_conn_on_sent(uint64_t now, lean_object *state, size_t n);
extern lean_object *ekk_conn_on_fail(lean_object *state);

void ekk_thread_init(void) { lean_initialize_thread(); }
void ekk_thread_fini(void) { lean_finalize_thread(); }

/* Conn.Action decoded for the loop. Constructor order in Conn.lean:
   recv (room) = 0, send (data, off) = 1, close = 2, none = 3. */
typedef struct {
    uint8_t kind;  /* 0 recv, 1 send, 2 close, 3 none */
    size_t room;   /* recv: most bytes to receive */
    size_t len;    /* send: bytes copied into out */
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
    if (act->kind == 0) {
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

void ekk_free(lean_object *state) { lean_dec(state); }
