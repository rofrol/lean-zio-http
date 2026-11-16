#include <lean/lean.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
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

/* The loop shuts down and declines the receive Lean asked for (or canceled
   the one in flight); Conn.step answers it with close. */
void ekk_refused(lean_object **state, uint8_t *out, size_t cap, ekk_action *act) {
    take(ekk_conn_on_refused(*state), state, out, cap, act);
}

void ekk_free(lean_object *state) { lean_dec(state); }

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
