// The transport: one zio.ev loop per thread, all accepting on one listening
// socket. The loop keeps no protocol or buffering state: each connection holds
// a Lean state (Server/Conn.lean), reports the outcome of every operation
// to it through glue.c, and performs the action it answers (receive, send,
// close, or a query, which the loop's PostgreSQL pool in pg.zig runs and whose
// result it reports back). Around that the loop owns admission (at most `max_conns`
// connections, the rest wait in the kernel's listen queue), the
// classification of accept errors, and the graceful shutdown on SIGTERM or
// SIGINT (README, "Production contract"), and the per-connection deadlines'
// timers: it arms one for the deadline and generation Lean's state names
// after each event, and one more for the head budget a pipelined request
// runs while a response is written (Conn.Phase.ahead), and reports their
// end back (Conn.Event.expired). While Lean's state watches for a next
// request's first byte (Conn.State.watches), the loop keeps a readiness
// poll on the socket beside the send and reports it (Conn.Event.arrived);
// the poll reads nothing, so the send stays the only data operation.
const std = @import("std");
const zio = @import("zio");
const ev = zio.ev;
const os = zio.os;
const net = os.net;
const pg = @import("pg.zig");

/// Conn.Action as decoded by glue.c.
pub const Action = extern struct {
    kind: u8, // 0 recv, 1 send, 2 close, 3 none, 4 query
    room: usize, // recv: most bytes to receive
    len: usize, // send: bytes glue.c copied into out
    query: ?*anyopaque, // query: the Server.Query, owned
    deadline: u8, // the deadline of Lean's new state: 0 none, 1 idle, 2 head, 3 body, 4 write
    gen: Gen, // with a deadline: its generation, owned; null without
    ahead: u8, // the head budget beside a send (Conn.Phase.ahead): 0 none, 2 head
    ahead_gen: Gen, // with ahead: its generation, owned; null without
    watch: u8, // 1: watch the socket for readability (Conn.State.watches)
};

pub const State = ?*anyopaque; // a Lean Conn.State, owned by the connection
/// A deadline period's generation: a Lean Nat, compared exactly (never truncated).
pub const Gen = ?*anyopaque;

extern fn ekk_open(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_recv(state: *State, data: [*]const u8, n: usize, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_sent(state: *State, n: usize, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_fail(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_refused(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_answer(state: *State, result: ?*anyopaque, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_expired(state: *State, kind: u8, gen: Gen, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_arrived(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_gen_eq(a: Gen, b: Gen) u8;
extern fn ekk_gen_free(g: Gen) void;
extern fn ekk_free(state: State) void;
extern fn ekk_string_cstr(s: *anyopaque) [*:0]const u8;
extern fn ekk_thread_init() void;
extern fn ekk_thread_fini() void;
extern fn ekk_stop_signals() c_int;
extern fn ekk_fd_room(need: c_ulong) c_int;
extern fn ekk_crash() void;

const alloc = std.heap.c_allocator;

// One receive takes at most min(room, recv_cap) bytes; Lean buffers them.
const recv_cap = 8192;
// One send writes at most out_cap bytes; Lean asks again for the rest.
const out_cap = 8192;
// Descriptors kept free besides the connections: the listening socket, the
// pipes, each loop's poller and wake handle, stdio.
const fd_reserve = 64;

/// Test settings, set by ekk_serve before any loop starts and read-only after
/// (the transport's tests, serve_test.zig, set them before their loop polls).
/// All zero in normal runs, where they cost one predictable branch per operation.
const Testing = struct {
    /// Most bytes per receive and per send when nonzero: forces short
    /// operations, so Lean sees partial sends and split requests.
    chunk: usize = 0,
    /// Every this-many-th completed receive, and every this-many-th completed
    /// send (each kind counted on its own, across loops), is reported to Lean
    /// as a failure when nonzero, its real result discarded.
    fail_every: u32 = 0,
    /// Prints `open <id>` and `free <id> <operations> <injected receive
    /// failures> <injected send failures>` on stderr per connection, gives each
    /// operation its own completion, and keeps freed connections and every
    /// operation allocated, so a duplicate or stale completion hits a check in
    /// `Conn.finish` instead of reused memory. Test runs only: it never frees them.
    trace: bool = false,
    /// When nonzero, the N-th successful receive (or send), counted across
    /// loops, prints `crash recv <id> <bytes>` (or `crash send`) and kills the
    /// process with SIGKILL after the kernel performed it and before Lean
    /// hears of it: the point where an effect precedes its record.
    crash_after_recv: u32 = 0,
    crash_after_send: u32 = 0,
};
pub var testing: Testing = .{};
var recv_count = std.atomic.Value(u32).init(0);
var send_count = std.atomic.Value(u32).init(0);
var recv_ok = std.atomic.Value(u32).init(0);
var send_ok = std.atomic.Value(u32).init(0);
var conn_ids = std.atomic.Value(u64).init(0);

/// Whether the receive or send that just completed, counted in `count`, is to
/// be reported as failed.
fn injectFailure(count: *std.atomic.Value(u32)) bool {
    if (testing.fail_every == 0) return false;
    return (count.fetchAdd(1, .monotonic) + 1) % testing.fail_every == 0;
}

/// Kills the process when this successful operation is the `at`-th (test setting).
fn crashPoint(count: *std.atomic.Value(u32), at: u32, kind: []const u8, id: u64, n: usize) void {
    if (at == 0) return;
    if (count.fetchAdd(1, .monotonic) + 1 != at) return;
    std.debug.print("crash {s} {d} {d}\n", .{ kind, id, n });
    ekk_crash();
}

fn capChunk(n: usize) usize {
    return if (testing.chunk == 0) n else @min(n, testing.chunk);
}

/// Ends the process on an error the server cannot recover from.
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Admission: slots taken by open connections and by armed accepts together,
/// never more than `max_conns`. A loop arms its accept only with a slot; the
/// accepted connection keeps that slot until its close, which releases it.
/// Liveness: a loop that finds no free slot pauses its acceptor and re-arms it
/// when one of its own connections closes; it pauses only when every slot is
/// taken, and then at least one slot is held by a connection whose loop will
/// see its close (a slot held by an armed accept becomes a connection or is
/// released on that loop), so whenever a slot is free some acceptor is armed
/// or is about to re-arm.
pub var slots_used = std.atomic.Value(u32).init(0);
pub var max_conns: u32 = 0;

fn reserveSlot() bool {
    var used = slots_used.load(.monotonic);
    while (used < max_conns) {
        used = slots_used.cmpxchgWeak(used, used + 1, .acq_rel, .monotonic) orelse return true;
    }
    return false;
}

fn releaseSlot() void {
    if (slots_used.fetchSub(1, .acq_rel) == 0) @panic("slot released twice");
}

/// One armed deadline timer: the deadline and generation it was armed for,
/// fixed for its life, so a callback reports the period it belongs to.
/// Each arm is allocated anew and never re-armed: a timer whose callback is
/// already on its way (`clearTimer` false) is left to it.
pub const Arm = struct {
    timer: ev.Timer,
    conn: *Conn,
    kind: u8,
    gen: Gen,
    /// The connection no longer waits for this arm (another period replaced
    /// it, or the connection closes) but its callback is still to run; the
    /// callback then only releases it.
    retired: bool = false,

    fn release(self: *Arm) void {
        ekk_gen_free(self.gen);
        alloc.destroy(self);
    }

    /// The timer ended. A retired arm only releases itself (and frees its
    /// closed connection when it was the last); a live arm reports its
    /// expiry to Lean (each arm names a pair of Lean's state, so it is
    /// current). The phase's own deadline closes
    /// (Conn.step_expired_current); the head budget beside a send closes
    /// when that head is incomplete and otherwise ends with nothing new
    /// (Conn.step_expired_ahead_partial, step_expired_ahead_complete), and
    /// the send goes on.
    fn timerCb(loop: *ev.Loop, c: *ev.Completion) void {
        const self: *Arm = @ptrCast(@alignCast(c.userdata.?));
        const conn = self.conn;
        pg.ownLoop(loop, &conn.lp.loop);
        if (self.retired) {
            self.release();
            conn.retired_arms -= 1;
            if (conn.retired_arms == 0 and conn.closed) conn.destroy();
            return;
        }
        const main = conn.arm == self;
        if (main) conn.arm = null else if (conn.ahead_arm == self) conn.ahead_arm = null else @panic("a timer that is neither current nor retired ended");
        var act: Action = undefined;
        ekk_expired(&conn.state, self.kind, self.gen, &conn.out, out_cap, &act);
        self.release();
        switch (act.kind) {
            2 => {
                if (act.deadline != 0 or act.ahead != 0) @panic("Lean closed with a deadline left");
                conn.expire();
            },
            3 => {
                if (main) @panic("Lean did not answer the current deadline's expiry with close");
                conn.apply(act);
            },
            else => @panic("Lean answered an expiry with neither close nor none"),
        }
    }
};

const Comp = union { recv: ev.NetRecv, send: ev.NetSend, close: ev.NetClose };

/// Whether the pair `kind`, `gen` is the one `a` was armed for.
fn same(a: *const Arm, kind: u8, gen: Gen) bool {
    return kind != 0 and kind == a.kind and ekk_gen_eq(a.gen, gen) != 0;
}
/// A query has no completion of its own: it is the connection's operation in
/// flight until the pool delivers its result.
const OpKind = enum { recv, send, close, query };

/// One submitted operation: its completion, stamped with its number on the
/// connection. Untraced, every operation of a connection reuses the slot
/// embedded in it; traced, each gets its own allocation, never freed, so a
/// duplicate or stale completion arrives at an address and number that are
/// not the current operation's and fails the check in `finish`.
const Op = struct {
    comp: Comp = undefined,
    kind: OpKind = .recv,
    id: u64,
    conn: *Conn,
};

pub const Conn = struct {
    fd: ev.Backend.NetHandle,
    lp: *LoopCtx,
    state: State = null,
    slot: Op = undefined,
    cur: ?*Op = null,
    /// The loop's list of open connections, for the shutdown.
    prev: ?*Conn = null,
    next: ?*Conn = null,
    in: [recv_cap]u8 = undefined,
    out: [out_cap]u8 = undefined,
    out_len: usize = 0,
    recv_iov: [1]os.iovec = undefined,
    send_iov: [1]os.iovec_const = undefined,
    /// Bytes the receive in flight may return.
    recv_len: usize = 0,
    /// Operations submitted and completed: the loop keeps at most one in
    /// flight per connection (Conn.lean's assumption), so a completion must
    /// be that one; anything else is a duplicate or stale one.
    started: u64 = 0,
    done: u64 = 0,
    freed: bool = false,
    id: u64 = 0,
    /// Failures injected after a receive or a send completed (`fail_every`).
    injected_recv: u64 = 0,
    injected_send: u64 = 0,
    /// The connection's place in its loop's PostgreSQL pool.
    waiter: pg.Waiter = .{ .deliver = answered },
    /// The timer of the deadline Lean's state runs under, if any.
    arm: ?*Arm = null,
    /// The timer of the head budget beside a send (Conn.Phase.ahead), if any.
    ahead_arm: ?*Arm = null,
    /// The readiness poll beside a send: in flight while `polling`. It is
    /// wanted (`watching`) while Lean's state watches and the send waits in
    /// the kernel (`sendParked`); one canceled because it is no longer
    /// wanted is `poll_stale` until its completion, which then reports
    /// nothing. A close waits for the poll's completion (`close_pending`),
    /// so that no completion outlives the connection.
    poll: ev.NetPoll = undefined,
    polling: bool = false,
    watching: bool = false,
    poll_stale: bool = false,
    close_pending: bool = false,
    /// Readiness polls started on this connection, for the tests.
    polls: u64 = 0,
    /// Retired arms whose callbacks are still to run: the connection is
    /// freed only after the last of them.
    ///
    /// Under the pinned zio (830564437b2c) a close never completes before a
    /// retired arm's callback, so `closeCb` always finds this at 0 and the
    /// `closed` branch in `Arm.timerCb` is not taken. From zio's source:
    /// every completion here keeps `defer_callback = true`
    /// (src/ev/completion.zig:275), so it is pushed on the loop's completion
    /// queue (src/ev/loop.zig:326-331), which runs first in, first out from a
    /// snapshot (loop.zig:1265-1269; queue.zig:43-57, 78-86); `checkTimers`
    /// only queues fired timers and runs no callback (loop.zig:1108-1118);
    /// `clearTimer` returns false only once the timer has completed or is
    /// being queued (loop.zig:735-743); this file takes both arms off before
    /// it submits a close (`apply` through `track` before `close`, `expire`
    /// through `disarm` before the canceled operation's completion closes,
    /// and `pollCb` submits a close only `close` deferred; `closeCb` panics
    /// on an arm left); and the kqueue, epoll and io_uring backends queue a
    /// close's completion only after it was submitted
    /// (src/ev/backends/kqueue.zig:634-641, backends/linux/epoll.zig:609-616,
    /// backends/linux/io_uring.zig:831-837). So a retired arm's callback is queued
    /// before the close is submitted and runs before its completion, and no
    /// test can force the other order through zio's API. zio documents none
    /// of this ordering, so the deferred free stays as a guard that relies
    /// on no order; a panic in its place would rely on undocumented behavior
    /// (decided 2026-11-17, item 5lkloz).
    retired_arms: u32 = 0,
    /// The current deadline expired while a receive or a send was in flight:
    /// Lean has closed, the operation is canceled, and its completion,
    /// whatever its result, only leads to the close.
    closing: bool = false,
    /// The close completed; the connection waits for its retired arms.
    closed: bool = false,

    /// Numbers and returns the next operation; ends the process if one is outstanding.
    fn begin(self: *Conn, kind: OpKind) *Op {
        if (self.freed or self.started != self.done) @panic("operation submitted while another is in flight");
        self.started += 1;
        const op = if (testing.trace) alloc.create(Op) catch fatal("no memory for a traced operation", .{}) else &self.slot;
        op.* = .{ .kind = kind, .id = self.started, .conn = self };
        self.cur = op;
        return op;
    }

    /// Accepts the completion `c` of `op` only if it is the outstanding
    /// operation's own completion; ends the process otherwise.
    fn finish(self: *Conn, op: *Op, c: *ev.Completion, comptime kind: std.meta.FieldEnum(Comp)) void {
        if (self.freed) @panic("completion after the connection was freed");
        if (self.started != self.done + 1 or self.cur != op or op.id != self.started or
            c != &@field(op.comp, @tagName(kind)).c) @panic("completion of no outstanding operation");
        self.done += 1;
        self.cur = null;
    }

    /// Keeps the timers on the two pairs of Lean's state, the phase's
    /// deadline and the head budget beside a send (taking ownership of both
    /// generations): an arm whose pair is still wanted, in either slot, is
    /// kept, so a period's due time is fixed when it starts, also when the
    /// head budget beside a send becomes the reading phase's own deadline
    /// (Conn.step_sent_handoff); arms of pairs no longer wanted are retired;
    /// a new pair is armed for its full budget from now.
    fn track(self: *Conn, kind: u8, gen: Gen, akind: u8, agen: Gen) void {
        var main: ?*Arm = null;
        var ahead: ?*Arm = null;
        for ([2]?*Arm{ self.arm, self.ahead_arm }) |slot| {
            const a = slot orelse continue;
            if (main == null and same(a, kind, gen)) {
                main = a;
            } else if (ahead == null and same(a, akind, agen)) {
                ahead = a;
            } else self.retire(a);
        }
        if (main != null) ekk_gen_free(gen) else if (kind != 0) main = self.newArm(kind, gen);
        if (ahead != null) ekk_gen_free(agen) else if (akind != 0) ahead = self.newArm(akind, agen);
        self.arm = main;
        self.ahead_arm = ahead;
    }

    fn newArm(self: *Conn, kind: u8, gen: Gen) *Arm {
        if (kind > budget_ms.len) @panic("Lean named an unknown deadline");
        const a = alloc.create(Arm) catch fatal("no memory for a deadline timer", .{});
        a.* = .{ .timer = ev.Timer.init(.none), .conn = self, .kind = kind, .gen = gen };
        a.timer.c.callback = Arm.timerCb;
        a.timer.c.userdata = a;
        self.lp.loop.setTimer(&a.timer, .fromMilliseconds(budget_ms[kind - 1]));
        return a;
    }

    /// Takes an arm off; one whose callback is already on its way is
    /// retired and released by that callback.
    fn retire(self: *Conn, a: *Arm) void {
        if (self.lp.loop.clearTimer(&a.timer)) {
            a.release();
        } else {
            a.retired = true;
            self.retired_arms += 1;
        }
    }

    /// Takes both arms off.
    pub fn disarm(self: *Conn) void {
        if (self.arm) |a| self.retire(a);
        if (self.ahead_arm) |a| self.retire(a);
        self.arm = null;
        self.ahead_arm = null;
    }

    /// Keeps the readiness poll in flight exactly while it is wanted. A poll
    /// canceled here completes later and reports nothing; until then no
    /// other can start, and its completion starts the next one if it is
    /// wanted again.
    fn watch(self: *Conn, want: bool) void {
        self.watching = want;
        if (want) {
            if (!self.polling) self.startPoll();
        } else if (self.polling and !self.poll_stale) {
            self.poll_stale = true;
            self.lp.loop.cancel(&self.poll.c);
        }
    }

    fn startPoll(self: *Conn) void {
        self.polling = true;
        self.poll_stale = false;
        self.polls += 1;
        self.poll = ev.NetPoll.init(self.fd, .recv);
        self.poll.c.callback = pollCb;
        self.poll.c.userdata = self;
        self.lp.loop.add(&self.poll.c);
    }

    /// The readiness poll completed. Readable (bytes, or the peer's end of
    /// input or an error, which the next receive then reports) while Lean
    /// still watches: reported as `arrived`, which starts the next request's
    /// head budget; the bytes stay in the kernel for that receive.
    fn pollCb(loop: *ev.Loop, c: *ev.Completion) void {
        const self: *Conn = @ptrCast(@alignCast(c.userdata.?));
        pg.ownLoop(loop, &self.lp.loop);
        if (self.freed or !self.polling) @panic("a poll completion with no poll in flight");
        self.polling = false;
        const stale = self.poll_stale;
        self.poll_stale = false;
        if (self.close_pending) {
            self.close_pending = false;
            return self.startClose();
        }
        const canceled = if (self.poll.getResult()) |_| false else |err| err == error.Canceled;
        if (stale) {
            if (self.watching) self.startPoll();
            return;
        }
        if (canceled) @panic("a poll canceled by no one");
        if (!self.watching) @panic("a live poll Lean no longer watches");
        var act: Action = undefined;
        ekk_arrived(&self.state, &self.out, out_cap, &act);
        self.apply(act);
    }

    /// Lean closed on an expiry: the other timer and the readiness poll are
    /// taken off, the receive or send in flight is canceled, and its
    /// completion closes. A query has no deadline (Conn.Phase.deadline), and
    /// a close is preceded by disarming.
    fn expire(self: *Conn) void {
        const op = self.cur orelse @panic("an expiry with no operation in flight");
        self.disarm();
        self.watch(false);
        self.closing = true;
        switch (op.kind) {
            .recv => self.lp.loop.cancel(&op.comp.recv.c),
            .send => self.lp.loop.cancel(&op.comp.send.c),
            .query, .close => @panic("a deadline expired while querying or closing"),
        }
    }

    /// The loop's shutdown drain ended: a send in flight is canceled and
    /// its completion closes, as after an expiry (`expire`); Lean is not
    /// asked, and its state is freed at the close. A receive in flight was
    /// canceled by the stop (`LoopCtx.stopCb`) and its completion closes
    /// through `refuse`; a close goes on. No query is in flight: the pool's
    /// `abort` has answered every one before this runs.
    fn cut(self: *Conn) void {
        if (self.closing or self.close_pending) return;
        const op = self.cur orelse @panic("a connection with no operation in flight at the drain's end");
        switch (op.kind) {
            .send => self.expire(),
            .recv, .close => {},
            .query => @panic("a query in flight after the pool's abort"),
        }
    }

    /// Whether the operation in flight is a send that zio could not
    /// complete when it was submitted: zio tries the syscall at once and
    /// parks the send only when the socket's buffer is full (sockreg.zig,
    /// `submitIo`), queuing a completed one's callback for later in the
    /// same poll (`defer_callback`).
    fn sendParked(self: *const Conn) bool {
        const op = self.cur orelse return false;
        return op.kind == .send and op.comp.send.c.loadState().phase == .running;
    }

    /// Performs the action Lean answered, after setting the timers to the
    /// deadlines of Lean's new state; during shutdown a receive is declined
    /// and reported as `refused` instead. While Lean's state watches, the
    /// readiness poll runs only beside a send that waits in the kernel: a
    /// send completed at submission is reported later in the same poll and
    /// followed at once by the response's next send (which gets the poll if
    /// it waits) or by the receive that finds any byte that arrived
    /// meanwhile, so the poll would only cost a poll(2) probe and a
    /// registration per response (README, "PostgreSQL", measured that
    /// probe's cost).
    fn apply(self: *Conn, act: Action) void {
        self.track(act.deadline, act.gen, act.ahead, act.ahead_gen);
        const wants = act.watch != 0;
        if (!wants) self.watch(false);
        switch (act.kind) {
            0 => {
                if (act.room == 0) return self.fail(); // excluded by Conn.step_recv
                if (self.lp.stopping) return self.refuse();
                self.startRecv(capChunk(@min(act.room, recv_cap)));
            },
            1 => {
                if (act.len == 0) return self.fail(); // excluded by Conn.step_send
                if (self.lp.drained) {
                    // The drain ended: nothing more is sent (`Conn.cut`).
                    self.disarm();
                    self.watch(false);
                    return self.close();
                }
                self.out_len = capChunk(act.len);
                self.startSend();
            },
            2 => self.close(),
            4 => {
                _ = self.begin(.query);
                // Printed before the pool sees the query, so a test that has
                // read it knows the query is queued or running.
                if (testing.trace) std.debug.print("query {d}\n", .{self.id});
                self.lp.pool.submit(&self.waiter, act.query);
            },
            // `none`: nothing new, the operation in flight goes on (an
            // arrival, or a head budget beside a send that ended on a
            // complete head). No event after close is reported (Conn.step_close).
            3 => if (self.cur == null) @panic("Lean answered none with no operation in flight"),
            else => @panic("Lean answered an unknown action"),
        }
        if (wants) self.watch(self.sendParked());
    }

    /// Reports a failed operation; Conn.step answers it with close.
    fn fail(self: *Conn) void {
        var act: Action = undefined;
        ekk_fail(&self.state, &self.out, out_cap, &act);
        if (act.kind != 2) @panic("Lean did not answer a failure with close");
        self.apply(act);
    }

    /// Reports a receive declined or canceled by the shutdown; Conn.step_refused: close.
    fn refuse(self: *Conn) void {
        var act: Action = undefined;
        ekk_refused(&self.state, &self.out, out_cap, &act);
        if (act.kind != 2) @panic("Lean did not answer a refused receive with close");
        self.apply(act);
    }

    fn startRecv(self: *Conn, n: usize) void {
        const op = self.begin(.recv);
        self.recv_len = n;
        op.comp = .{ .recv = ev.NetRecv.init(self.fd, .fromSlice(self.in[0..n], &self.recv_iov), .{}) };
        op.comp.recv.c.callback = recvCb;
        op.comp.recv.c.userdata = op;
        self.lp.loop.add(&op.comp.recv.c);
    }

    fn recvCb(loop: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        pg.ownLoop(loop, &self.lp.loop);
        self.finish(op, c, .recv);
        if (self.closing) return self.close(); // Lean closed on an expiry; the result is not reported
        const n = op.comp.recv.getResult() catch |err| switch (err) {
            error.Canceled => return self.refuse(), // only the shutdown cancels a receive
            else => return self.fail(),
        };
        if (n > self.recv_len) @panic("receive returned more bytes than asked");
        crashPoint(&recv_ok, testing.crash_after_recv, "recv", self.id, n);
        if (injectFailure(&recv_count)) {
            self.injected_recv += 1;
            return self.fail();
        }
        var act: Action = undefined;
        ekk_recv(&self.state, &self.in, n, &self.out, out_cap, &act);
        self.apply(act);
    }

    fn startSend(self: *Conn) void {
        const op = self.begin(.send);
        op.comp = .{ .send = ev.NetSend.init(self.fd, .fromSlice(self.out[0..self.out_len], &self.send_iov), .{}) };
        op.comp.send.c.callback = sendCb;
        op.comp.send.c.userdata = op;
        self.lp.loop.add(&op.comp.send.c);
    }

    fn sendCb(loop: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        pg.ownLoop(loop, &self.lp.loop);
        self.finish(op, c, .send);
        if (self.closing) return self.close(); // Lean closed on an expiry; the result is not reported
        const n = op.comp.send.getResult() catch return self.fail();
        if (n > self.out_len) @panic("send reported more bytes than given");
        crashPoint(&send_ok, testing.crash_after_send, "send", self.id, n);
        if (injectFailure(&send_count)) {
            self.injected_send += 1;
            return self.fail();
        }
        var act: Action = undefined;
        ekk_sent(&self.state, n, &self.out, out_cap, &act);
        self.apply(act);
    }

    /// The pool's result for the query in flight (Conn.step_query: the
    /// connection waits in `querying` for exactly this event).
    fn answered(w: *pg.Waiter, result: ?*anyopaque) void {
        const self: *Conn = @fieldParentPtr("waiter", w);
        if (self.freed) @panic("a query result after the connection was freed");
        const op = self.cur orelse @panic("a query result with no operation in flight");
        if (op.kind != .query or self.started != self.done + 1 or op.id != self.started) @panic("a query result for no outstanding query");
        self.done += 1;
        self.cur = null;
        var act: Action = undefined;
        ekk_answer(&self.state, result, &self.out, out_cap, &act);
        self.apply(act);
    }

    /// Closes once the readiness poll, if one is in flight, has completed:
    /// its completion refers to the connection.
    fn close(self: *Conn) void {
        if (self.polling) {
            if (!self.poll_stale) @panic("a close with a poll Lean still watches");
            self.close_pending = true;
            return;
        }
        self.startClose();
    }

    fn startClose(self: *Conn) void {
        const op = self.begin(.close);
        op.comp = .{ .close = ev.NetClose.init(self.fd) };
        op.comp.close.c.callback = closeCb;
        op.comp.close.c.userdata = op;
        self.lp.loop.add(&op.comp.close.c);
    }

    fn closeCb(loop: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        pg.ownLoop(loop, &self.lp.loop);
        self.finish(op, c, .close);
        if (self.arm != null or self.ahead_arm != null) @panic("a connection closed with a deadline armed");
        if (self.polling) @panic("a connection closed with its poll in flight");
        ekk_free(self.state);
        self.state = null;
        const lp = self.lp;
        lp.unlink(self);
        if (lp.stopping and lp.head == null) lp.endDrain();
        releaseSlot();
        if (testing.trace) {
            std.debug.print("free {d} {d} {d} {d}\n", .{ self.id, self.done, self.injected_recv, self.injected_send });
            self.freed = true; // kept allocated, like its operations: a later completion panics in finish()
        }
        self.closed = true;
        if (self.retired_arms == 0) self.destroy();
        lp.resumeAccept();
    }

    /// Frees a closed connection none of whose timers is still to run.
    fn destroy(self: *Conn) void {
        if (!testing.trace) alloc.destroy(self);
    }
};

/// One loop and what it owns: its acceptor, its open connections and its
/// shutdown handle. Touched only by the loop's own thread, except `stop`,
/// which the signal thread notifies.
pub const LoopCtx = struct {
    loop: ev.Loop = undefined,
    lfd: ev.Backend.NetHandle,
    accept: ev.NetAccept = undefined,
    /// An accept is in flight (it holds a slot).
    armed: bool = false,
    /// No slot was free when the acceptor was to be re-armed.
    paused: bool = false,
    stopping: bool = false,
    stop: ev.Async = undefined,
    /// The shutdown's drain (`drain_ms`), armed by the stop while
    /// connections are open and taken off when the last of them closes.
    drain: ev.Timer = undefined,
    drain_armed: bool = false,
    /// The drain ended: every connection closes, and a send Lean asks for
    /// afterwards (a handler answered by `Pool.abort`) closes instead.
    drained: bool = false,
    head: ?*Conn = null,
    /// The loop's PostgreSQL connections (pg.zig).
    pool: pg.Pool = undefined,

    fn link(self: *LoopCtx, conn: *Conn) void {
        conn.next = self.head;
        if (self.head) |h| h.prev = conn;
        self.head = conn;
    }

    fn unlink(self: *LoopCtx, conn: *Conn) void {
        if (conn.prev) |p| p.next = conn.next else self.head = conn.next;
        if (conn.next) |n| n.prev = conn.prev;
        conn.prev = null;
        conn.next = null;
    }

    /// Arms the accept with a free slot, or pauses until a connection of this
    /// loop closes.
    fn armAccept(self: *LoopCtx) void {
        if (self.stopping or self.armed) return;
        if (!reserveSlot()) {
            self.paused = true;
            return;
        }
        self.paused = false;
        self.armed = true;
        self.accept = ev.NetAccept.init(self.lfd, null, null);
        self.accept.c.callback = acceptCb;
        self.accept.c.userdata = self;
        self.loop.add(&self.accept.c);
    }

    fn resumeAccept(self: *LoopCtx) void {
        if (self.paused) self.armAccept();
    }

    fn acceptCb(loop: *ev.Loop, c: *ev.Completion) void {
        const self: *LoopCtx = @ptrCast(@alignCast(c.userdata.?));
        pg.ownLoop(loop, &self.loop);
        self.armed = false;
        const fd = self.accept.getResult() catch |err| {
            releaseSlot();
            switch (err) {
                // Errors of the one pending connection (accept(2) on Linux:
                // "treat them like EAGAIN by retrying"), and a spurious wake.
                error.WouldBlock, error.ConnectionAborted, error.ProtocolFailure, error.BlockedByFirewall, error.NetworkDown => {},
                error.Canceled => if (!self.stopping) fatal("accept canceled outside the shutdown", .{}),
                // Out of descriptors or memory: --max-conns is checked against
                // RLIMIT_NOFILE at startup, so this is pressure from outside the
                // server; nothing of ours waits for it to end (README).
                error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => fatal("accept: {}", .{err}),
                // An error of the listening socket itself, or one zio does not
                // name (Unexpected): fatal. Linux's other pending-connection
                // errnos in accept(2) (ENETUNREACH, EHOSTUNREACH, EHOSTDOWN,
                // ENONET, ENOPROTOOPT, EOPNOTSUPP) would reach here too, as the
                // pinned zio maps them to Unexpected or OperationNotSupported
                // (src/os/net.zig, errnoToAcceptError); the Linux sources read
                // do not return them from TCP's accept (README, "Production
                // contract", "Accept errors").
                else => fatal("accept: {}", .{err}),
            }
            return self.armAccept();
        };
        if (self.stopping) {
            // Accepted while the cancel was on its way: not served.
            net.close(fd);
            releaseSlot();
            return;
        }
        // TCP_NODELAY comes from the listener (openListener).
        const conn = alloc.create(Conn) catch fatal("no memory for a connection", .{});
        conn.* = .{ .fd = fd, .lp = self, .id = conn_ids.fetchAdd(1, .monotonic) };
        self.link(conn);
        if (testing.trace) std.debug.print("open {d}\n", .{conn.id});
        var act: Action = undefined;
        ekk_open(&conn.state, &conn.out, out_cap, &act);
        conn.apply(act);
        self.armAccept();
    }

    /// The shutdown, on the loop's own thread: no more accepts, and every
    /// receive in flight is canceled (its callback reports `refused`, or the
    /// result it had). Sends run to completion; Lean still answers requests
    /// already buffered, and every receive it asks for afterwards is declined.
    /// While connections are open the drain runs (`drainCb`), so the shutdown
    /// ends by `drain_ms` at the latest, plus a connect in flight that no
    /// query waits for (its own `--pg-connect-ms`). `loop.run` returns once
    /// nothing of this loop is in flight.
    pub fn stopCb(loop: *ev.Loop, c: *ev.Completion) void {
        const self: *LoopCtx = @ptrCast(@alignCast(c.userdata.?));
        pg.ownLoop(loop, &self.loop);
        self.stopping = true;
        if (self.armed) self.loop.cancel(&self.accept.c);
        self.paused = false; // armAccept refuses from now on
        var receives: u32 = 0;
        var sends: u32 = 0;
        var it = self.head;
        while (it) |conn| : (it = conn.next) {
            if (conn.cur) |op| switch (op.kind) {
                .recv => {
                    receives += 1;
                    self.loop.cancel(&op.comp.recv.c);
                },
                .send => sends += 1,
                .close, .query => {},
            };
        }
        // Queries in flight and waiting still run; idle database connections close.
        self.pool.stop();
        if (self.head != null) {
            self.drain = ev.Timer.init(.none);
            self.drain.c.callback = drainCb;
            self.drain.c.userdata = self;
            self.drain_armed = true;
            self.loop.setTimer(&self.drain, .fromMilliseconds(drain_ms));
        }
        // The shutdown test checks that a send was in flight when the stop came.
        if (testing.trace) std.debug.print("stop {d} {d}\n", .{ receives, sends });
    }

    /// The last connection closed during the shutdown: the drain has
    /// nothing left to bound. A callback already on its way finds no
    /// connection and an empty pool queue.
    fn endDrain(self: *LoopCtx) void {
        if (self.drain_armed and self.loop.clearTimer(&self.drain)) self.drain_armed = false;
    }

    /// The drain ended with work still open: the pool answers every query
    /// and closes its sessions (`Pool.abort`), a handler that answers then
    /// gets its connection closed instead of a send (`Conn.apply`), and
    /// every send in flight is canceled and its connection closes
    /// (`Conn.cut`). No send starts after the drain's end.
    fn drainCb(loop: *ev.Loop, c: *ev.Completion) void {
        const self: *LoopCtx = @ptrCast(@alignCast(c.userdata.?));
        pg.ownLoop(loop, &self.loop);
        self.drain_armed = false;
        self.drained = true;
        self.pool.abort();
        var it = self.head;
        while (it) |conn| : (it = conn.next) conn.cut();
        if (testing.trace) std.debug.print("drain ended\n", .{});
    }
};

var loops: []LoopCtx = &.{};
/// The PostgreSQL connection string and the connections per loop (0: none).
var pg_conninfo: [*:0]const u8 = "";
var pg_conns: u32 = 0;
/// Every session's startup options (pg.c, ekk_pg_options) and the pool's
/// deadline budgets (Transport.Options: pgQueryMs, pgQueryMaxMs,
/// pgConnectMs, pgStatementMs).
var pg_options: [*:0]const u8 = "";
var pg_budgets: pg.Budgets = .{};

extern fn ekk_pg_options(conninfo: [*:0]const u8, statement_ms: c_uint, out: *?[*:0]u8) c_int;
/// Each per-connection deadline's budget in milliseconds, at least 1
/// (Transport.Options: idleMs, headMs, bodyMs, writeMs), indexed by the
/// deadline's code (Transport.deadlineCode) less 1: idle, head, body, write.
/// The tests (serve_test.zig) set it themselves; 0 there makes a timer due
/// at once.
pub var budget_ms: [4]u32 = .{ 1, 1, 1, 1 };
/// The shutdown's drain in milliseconds, at least 1 (Transport.Options.drainMs):
/// from a loop's stop to the forced close of what is still open there. The
/// tests (serve_test.zig) set it themselves.
pub var drain_ms: u32 = 1;

/// Writes a loop's one-byte report; a write that fails would leave the
/// waiter blocked forever, so it ends the process instead.
fn sendReport(report: std.c.fd_t, code: u8) void {
    if (std.c.write(report, &[1]u8{code}, 1) != 1) fatal("could not report a loop's state", .{});
}

/// Sets up `lp`'s loop on the calling thread, which then owns it: its
/// PostgreSQL pool, its shutdown handle and its armed acceptor. Returns false,
/// with nothing left to deinit, when the loop could not be set up. The tests
/// (serve_test.zig) drive a loop set up this way themselves.
pub fn startLoop(lp: *LoopCtx) bool {
    lp.loop.init(.{ .allocator = alloc }) catch return false;
    const slots = alloc.alloc(pg.Slot, pg_conns) catch {
        lp.loop.deinit();
        return false;
    };
    lp.pool.init(&lp.loop, pg_conninfo, pg_options, pg_budgets, slots, testing.trace);
    lp.stop = ev.Async.init();
    lp.stop.c.callback = LoopCtx.stopCb;
    lp.stop.c.userdata = lp;
    lp.loop.add(&lp.stop.c);
    lp.armAccept();
    return true;
}

/// Sets up loop `i` with its acceptor and shutdown handle, reports the outcome
/// as one byte on `report` (0 ready, 1 failed), runs the loop until its
/// shutdown is complete, then reports 2 on `done`.
fn runLoop(i: usize, lean_thread: bool, report: std.c.fd_t, done: std.c.fd_t) void {
    if (lean_thread) ekk_thread_init();
    defer if (lean_thread) ekk_thread_fini();
    const lp = &loops[i];
    if (!startLoop(lp)) {
        sendReport(report, 1);
        return;
    }
    defer lp.loop.deinit();
    sendReport(report, 0);
    lp.loop.run() catch |err| fatal("loop failed: {}", .{err});
    if (lp.head != null) @panic("a loop ended with connections open");
    sendReport(done, 2);
}

/// Prints "ready" once one success byte has arrived from each loop, then
/// waits for a shutdown signal and notifies every loop's `stop` handle.
fn awaitReadyThenStop(ready: std.c.fd_t, threads: u32, stop_fd: c_int) void {
    var got: u32 = 0;
    while (got < threads) : (got += 1) {
        var b: [1]u8 = undefined;
        if (std.c.read(ready, &b, 1) != 1 or b[0] != 0) fatal("a loop failed to start", .{});
    }
    std.debug.print("ready\n", .{}); // bench.sh and the tests wait for this line
    var b: [1]u8 = undefined;
    while (true) {
        const r = std.c.read(stop_fd, &b, 1);
        if (r == 1) break;
        if (r < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
        fatal("the shutdown pipe failed", .{});
    }
    // zio's `Async.notify` is safe at any time while the `Async` itself is
    // alive, also against its loop ending and being deinitialized (zio
    // 830564437b2c, https://github.com/lalinsky/zio/pull/928). Each `stop`
    // lives in `loops`, which is never freed, so it outlives every notify
    // here, also one still running after `ekk_serve` has returned (this
    // thread is detached and never joined).
    for (loops) |*lp| lp.stop.notify();
}

/// Reports a failed setup call on the listening socket with its errno (a
/// port another process holds: EADDRINUSE) and closes the socket, for
/// `openListener` to return null.
fn setupFailed(lfd: std.c.fd_t, what: []const u8, port: u16) ?Listening {
    const e = std.c._errno().*;
    const name = std.enums.tagName(std.c.E, @enumFromInt(e)) orelse "unknown";
    std.debug.print("cannot {s} 127.0.0.1:{d}: errno {d} ({s})\n", .{ what, port, e, name });
    net.close(lfd);
    return null;
}

/// The listening socket and the port it is bound to (the kernel's pick when
/// `port` was 0).
pub const Listening = struct { fd: std.c.fd_t, port: u16 };

/// Opens the nonblocking listening socket on 127.0.0.1:`port` (port 0: one
/// the kernel picks) with SO_REUSEADDR and TCP_NODELAY. Reports a failure and
/// returns null. `ekk_serve` and the transport's tests (serve_test.zig) both
/// open their listener here.
pub fn openListener(port: u16) ?Listening {
    const lfd = net.socket(.ipv4, .stream, .ip, .{ .nonblocking = true }) catch |e| {
        std.debug.print("cannot open the listening socket: {s}\n", .{@errorName(e)});
        return null;
    };
    const one: c_int = 1;
    net.setsockopt(lfd, net.SOL.SOCKET, net.SO.REUSEADDR, std.mem.asBytes(&one)) catch |e| {
        std.debug.print("cannot set SO_REUSEADDR on the listening socket: {s}\n", .{@errorName(e)});
        net.close(lfd);
        return null;
    };
    // TCP_NODELAY is set once here and every accepted connection inherits it,
    // so `acceptCb` sets nothing on the connections. The basis is zio's
    // maintainer, answering our report of EINVAL warnings from a per-connection
    // setsockopt (https://github.com/lalinsky/zio/issues/926#issuecomment-6942382039,
    // lalinsky, 2026-11-17): "Since #870, which is in 9bef33d, `TCP_NODELAY` is
    // set once on the listening socket and accepted connections inherit it.
    // [...] If you set `TCP_NODELAY` on the listener next to `SO_REUSEADDR` and
    // drop the per-connection call, the warnings go away, and you save a syscall
    // per connection." The pinned zio's own listen does the same (src/net.zig,
    // `listen`: "Accepted sockets inherit TCP_NODELAY from the listener.").
    // serve_test.zig checks the accepted connection's TCP_NODELAY on macOS;
    // Linux is not yet checked by a run there.
    net.setNoDelay(lfd, true) catch |e| {
        std.debug.print("cannot set TCP_NODELAY on the listening socket: {s}\n", .{@errorName(e)});
        net.close(lfd);
        return null;
    };
    // bind, listen and getsockname through libc, so a failure reports its errno.
    var sa: net.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    var sa_len: std.c.socklen_t = @sizeOf(net.sockaddr.in);
    if (std.c.bind(lfd, @ptrCast(&sa), sa_len) != 0) return setupFailed(lfd, "bind", port);
    if (std.c.listen(lfd, 4096) != 0) return setupFailed(lfd, "listen on", port);
    // With port 0 the kernel picked the port: report the one it gave.
    if (std.c.getsockname(lfd, @ptrCast(&sa), &sa_len) != 0) return setupFailed(lfd, "read the address of", port);
    return .{ .fd = lfd, .port = std.mem.bigToNative(u16, sa.port) };
}

/// Serves on 127.0.0.1:port (port 0: one the kernel picks) with `threads`
/// loops (the calling thread runs the last one) and at most `maxc`
/// connections; once listening, prints "listening on 127.0.0.1:PORT with ..."
/// with the port it got, then "ready" once every loop has registered its
/// acceptor. On SIGTERM or SIGINT every loop shuts down
/// gracefully; once all have, it prints "stopped" and returns 0. Each loop
/// has at most `conns` PostgreSQL connections to `conninfo` (a Lean String,
/// kept for the process's life). `idle_ms` to `write_ms` are the
/// per-connection deadlines' budgets (`budget_ms`); `query_ms` to
/// `statement_ms` the pool's (`pg_budgets`, and PostgreSQL's
/// statement_timeout in `pg_options`); `drain` the shutdown's (`drain_ms`). The rest are the test settings
/// (`Testing`), all zero in normal runs. Returns 1 on setup failure.
export fn ekk_serve(port: u16, threads: u32, maxc: u32, conninfo: *anyopaque, conns: u32, idle_ms: u32, head_ms: u32, body_ms: u32, write_ms: u32, query_ms: u32, query_max_ms: u32, connect_ms: u32, statement_ms: u32, drain: u32, chunk: usize, fail_every: u32, trace: u8, crash_recv: u32, crash_send: u32) callconv(.c) u8 {
    if (threads == 0 or maxc == 0) return 1;
    budget_ms = .{ idle_ms, head_ms, body_ms, write_ms };
    for (budget_ms) |ms| if (ms == 0) return 1;
    if (query_ms == 0 or query_max_ms < query_ms or connect_ms == 0 or statement_ms == 0 or drain == 0) return 1;
    drain_ms = drain;
    pg_budgets = .{ .query_ms = query_ms, .query_max_ms = query_max_ms, .connect_ms = connect_ms };
    pg_conninfo = ekk_string_cstr(conninfo);
    pg_conns = conns;
    if (conns > 0 and pg.ekk_pg_libpq_supported() == 0) {
        std.debug.print("libpq {d} is not supported: the PostgreSQL pool needs libpq 17 or later\n", .{pg.ekk_pg_libpq_version()});
        return 1;
    }
    if (conns > 0) {
        var options: ?[*:0]u8 = null;
        switch (ekk_pg_options(pg_conninfo, statement_ms, &options)) {
            0 => pg_options = options.?,
            1 => {
                std.debug.print("--pg names a service (or PGSERVICE is set): the pool sets statement_timeout through the startup options, which would replace the service file's; give the settings in --pg instead\n", .{});
                return 1;
            },
            3 => {
                std.debug.print("the startup options of --pg (or PGOPTIONS) end in an unpaired backslash, which would escape the statement_timeout the pool appends\n", .{});
                return 1;
            },
            else => return 1,
        }
    }
    testing = .{ .chunk = chunk, .fail_every = fail_every, .trace = trace != 0, .crash_after_recv = crash_recv, .crash_after_send = crash_send };
    max_conns = maxc;
    // Each database connection holds libpq's socket and the loop's duplicate.
    if (ekk_fd_room(@as(c_ulong, maxc) + fd_reserve + 2 * @as(c_ulong, threads) * (1 + @as(c_ulong, conns))) != 0) {
        std.debug.print("RLIMIT_NOFILE cannot hold --max-conns {d} connections\n", .{maxc});
        return 1;
    }
    const stop_fd = ekk_stop_signals();
    if (stop_fd < 0) return 1;
    const listener = openListener(port) orelse return 1;
    const lfd = listener.fd;
    // The checks read the address from this line (bench/lib.sh, bench/boundary,
    // bench/dbcheck); it comes only after listen succeeded.
    std.debug.print("listening on 127.0.0.1:{d} with {d} loops, at most {d} connections\n", .{ listener.port, threads, maxc });

    loops = alloc.alloc(LoopCtx, threads) catch return 1;
    // Every loop accepts on the same `lfd`, yet each accept's callback runs
    // on the thread of the loop it was added to, because the loops share no
    // zio LoopGroup (startLoop passes none). In the pinned zio (830564437b2c)
    // a socket op parked on another loop's (fd, direction) registration is
    // completed by that loop, on its thread (src/ev/sockreg.zig:213-271,
    // `service` at 276-315 calling `markCompletedFromBackend`, which calls the
    // callback inline: src/ev/loop.zig:310-362). That registration table is
    // "shared by every loop in a group" (src/ev/sockreg.zig:105), and
    // "Grouped loops service and complete each other's operations"
    // (src/ev/loop.zig:572); a loop given no `loop_group` uses its own
    // `internal_loop_group` (src/ev/loop.zig:516, 559-563), so it parks on
    // and services only its own table and poller. Passing a shared
    // `loop_group` to `loop.init` would let `acceptCb` run on another loop's
    // thread against this loop's state. Checks keep this: serve_test.zig
    // checks that `startLoop` leaves its loop in the loop's own internal
    // group and that no identifier or string literal in the transport's Zig
    // sources is `loop_group` or `LoopGroup`; and every callback panics when
    // zio calls it with another loop than its own (`pg.ownLoop`). Recheck at
    // each update of zio.
    for (loops) |*lp| lp.* = .{ .lfd = lfd };
    var ready: [2]std.c.fd_t = undefined;
    var done: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&ready) != 0 or std.c.pipe(&done) != 0) return 1;
    const waiter = std.Thread.spawn(.{}, awaitReadyThenStop, .{ ready[0], threads, stop_fd }) catch return 1;
    waiter.detach();
    var i: u32 = 1;
    while (i < threads) : (i += 1) {
        const t = std.Thread.spawn(.{}, runLoop, .{ i, true, ready[1], done[1] }) catch return 1;
        t.detach();
    }
    runLoop(0, false, ready[1], done[1]);
    var stopped: u32 = 0;
    while (stopped < threads) : (stopped += 1) {
        var b: [1]u8 = undefined;
        if (std.c.read(done[0], &b, 1) != 1 or b[0] != 2) fatal("a loop failed to stop", .{});
    }
    std.debug.print("stopped\n", .{});
    return 0;
}
