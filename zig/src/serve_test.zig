//! Controlled-interleaving tests of the zio contracts that serve.zig's graceful
//! shutdown and admission rely on (`zig build test`;
//! docs/production-contract.md). serve.zig runs on real zio.ev loops and real sockets. glue.c
//! (the Lean side) is replaced by the fake below, which always gives the same
//! answers: after an open, and after a receive that returned bytes, it asks
//! to receive again; at end of input, on a refusal, on a failure and on an
//! expiry it asks to close. When a test sets `open_dl` and `recv_dl`, its
//! states run under those deadlines, each receive with bytes starting a new
//! generation, as Lean's do (Conn.step). When a test sets `respond`, a
//! receive whose first byte is 'R' is a request: the fake answers it with a
//! response of that many bytes under the write deadline, watches for the
//! next request's first byte while it is sent, and runs that request's head
//! budget beside the send from its arrival, as Lean's Conn.step does for a
//! pipelined request (item dv6ikn). Clients connect over TCP on 127.0.0.1, and
//! in the tests whose premise is a send that waits in the kernel or writes
//! only part of what it was asked, over a Unix-domain stream socket, whose
//! buffer gains room only when its peer reads (item emb2ob: loopback TCP's
//! buffers are the kernel's to size and drain, and differ between macOS and
//! Linux). Before a single-loop test
//! polls its loop for an event, it waits (`awaitReadable`) until the kernel
//! has made that event ready: a connection queued on the listening socket, or
//! bytes readable at the server's end. The loop's nonblocking polls then find
//! it at once.
//!
//! Each call into the fake is an event: a fixed-size record written to a pipe
//! in one write, which is atomic up to PIPE_BUF. A test whose loops run on
//! other threads therefore reads every loop's events in the order each loop
//! made them.
//!
//! These tests and pg_test.zig's run on macOS (kqueue, `./check.sh`) and on
//! Linux (epoll and io_uring, `./linux-check.sh`, docs/running.md; rerun it
//! at each zio update and update this record). Last Linux run, 2026-11-18
//! (item qgrnr3, after its ten tests of explicitly delivered orderings were
//! added): OrbStack on the M1, aarch64, kernel
//! 7.2.12-orbstack-00394-gbecdd6130068, Debian 13.7, Zig 0.17.1, Lean
//! nightly-2026-11-17, libpq 17.12, zio 53ed3c377317. `./linux-check.sh`
//! exit 0, on epoll and on io_uring each: `zig build test` passed (it prints
//! no count; serve_test.zig then held 40 tests, all 40 passing on macOS),
//! pg_glue_test passed, and the rest of `./check.sh`, bench/dbcheck on the
//! container's private cluster included. On the production host, 2026-11-17 (item 53rwgc,
//! 3ce9bdc; its rerun of 2026-11-18 is in docs/reports/httparena-vps.md): x86_64, 2 vCPU, kernel 6.12.74+deb13+1-amd64,
//! Debian 13.4, the same versions, binaries cross-built by
//! bench/arena/build.sh: serve_test's 25 tests and pg_test's 31 passed on
//! epoll and on io_uring each, and pg_glue_test passed. In item wi7efy's run (zio 830564437b2c), with serve.zig's
//! `startSend` not trying the send itself (a mutation), 3 tests failed on io_uring, among
//! them "a response sent at once starts no poll ...". A diagnostic loop of
//! 30 runs of the serve_test binary on each backend: 0 failures.
const std = @import("std");
const zio = @import("zio");
const ev = zio.ev;
const build_options = @import("build_options");
const serve = @import("serve.zig");

const c = std.c;
extern "c" fn socket(domain: c_uint, kind: c_uint, protocol: c_uint) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

/// The most nonblocking polls a single-loop test makes while it waits for an
/// event that its last step has already made ready: running out means the
/// expected callback never ran.
const max_steps = 1000;

// ---- the fake glue.c ----

const Kind = enum(u8) { open, recv, refused, fail, free, ready, snapshot, done, expired, arrived, written, sent };

const Event = extern struct {
    kind: Kind,
    /// The loop whose thread made the event (multi-loop test).
    loop: u8 = 0,
    /// snapshot: the loop's acceptor is armed, or paused.
    armed: bool = false,
    paused: bool = false,
    conn: u32 = 0,
    /// recv: bytes received (0: end of input); snapshot: open connections;
    /// expired: the generation.
    n: u32 = 0,
    /// snapshot: `slots_used`, as the loop read it.
    slots: u32 = 0,
    /// recv: the first byte received; expired: the deadline's code.
    byte: u8 = 0,
    /// sent: the bytes the completed send was asked to write (`n` is what
    /// it wrote), and the response's bytes still unsent after it.
    asked: u32 = 0,
    left: u32 = 0,
};

/// Deadline codes as glue.c reports them (Transport.deadlineCode).
const none_code: u8 = 0;
const idle_code: u8 = 1;
const head_code: u8 = 2;
const write_code: u8 = 4;

/// The Lean state of one fake connection: the deadline it runs under and
/// its generation; while it writes a response, the bytes still to send and
/// whether a next request's head budget runs beside the send (in
/// generation `gen + 1`, Conn.Phase.ahead).
/// `held`: the next request's head is complete in Lean's buffer, so the
/// fake no longer watches (Conn.State.watches needs an empty buffer).
/// `asked`: the length of the send in flight.
const FakeConn = struct { id: u32, loop: u8, dl: u8 = none_code, gen: u32 = 0, left: usize = 0, asked: usize = 0, ahead: bool = false, held: bool = false };

/// The deadline a new connection runs under, and the one after each receive
/// with bytes. Tests set them before a loop starts.
var open_dl: u8 = none_code;
var recv_dl: u8 = none_code;
/// When set, a receive with bytes keeps the connection's deadline and
/// generation (a fragment within one period, as Lean's head fragments).
var recv_keeps = false;
/// When nonzero, the size of the response to a request ('R').
var respond: usize = 0;
/// When set, the head behind a response counts as complete in Lean's
/// buffer: its budget's expiry during the write ends it without a close
/// (Conn.step_expired_ahead_complete).
var ahead_complete = false;
/// When nonzero, a new connection starts with a response of that many
/// bytes (the fake speaks first), sent under the write deadline with the
/// readiness poll beside it.
var respond_on_open: usize = 0;
/// When set, every send completion the fake hears of is a `sent` event.
var report_sent = false;
/// When set, the next send completion makes this connection's current
/// deadline due (a test hook, as `dueNow`) before the fake answers it:
/// after the poll's timer check, so the loop dispatches the completion with
/// the expiry due and reports that expiry only at its next timer check.
/// `due_injected` is the due time it set.
var due_on_sent: ?*serve.Conn = null;
var due_injected: ?@FieldType(ev.Timer, "deadline") = null;

var events: [2]c.fd_t = .{ -1, -1 };
var next_conn = std.atomic.Value(u32).init(0);
/// The room the fake asks for in each receive. Tests set it before a loop starts.
var room: usize = 64;
/// The loop the calling thread runs (multi-loop test).
threadlocal var loop_index: u8 = 0;
/// Set while serve.zig's `stopCb` runs (`stopWrapped`). A call into the
/// fake then would be a callback made synchronously from inside the
/// shutdown's traversal of the connections.
threadlocal var in_stop = false;

fn emit(e: Event) void {
    if (c.write(events[1], std.mem.asBytes(&e).ptr, @sizeOf(Event)) != @sizeOf(Event)) @panic("could not write an event");
}

fn enter(comptime name: []const u8) void {
    if (in_stop) @panic(name ++ " was called back synchronously from inside stopCb's traversal");
}

fn connOf(state: serve.State) *FakeConn {
    return @ptrCast(@alignCast(state orelse @panic("a call with no connection state")));
}

fn answer(act: *serve.Action, kind: u8, n: usize) void {
    act.* = .{ .kind = kind, .room = n, .len = 0, .query = null, .deadline = none_code, .gen = null, .ahead = none_code, .ahead_gen = null, .watch = 0 };
}

/// A generation as the loop holds it: never null.
fn genPtr(g: u32) serve.Gen {
    return @ptrFromInt(@as(usize, g) + 1);
}

/// Asks to receive `n` bytes, under the connection's deadline.
fn answerRecv(act: *serve.Action, fc: *const FakeConn, n: usize) void {
    answer(act, 0, n);
    act.deadline = fc.dl;
    if (fc.dl != none_code) act.gen = genPtr(fc.gen);
}

/// Answers `kind` (send or none) while writing: the write deadline, the
/// head budget beside it once a next request's byte arrived, and the watch
/// until then (Conn.State.watches).
fn answerWriting(act: *serve.Action, fc: *FakeConn, kind: u8, out: [*]u8, cap: usize) void {
    answer(act, kind, 0);
    if (kind == 1) {
        act.len = @min(cap, fc.left);
        fc.asked = act.len;
        @memset(out[0..act.len], 'x');
    }
    act.deadline = fc.dl;
    act.gen = genPtr(fc.gen);
    if (fc.ahead) {
        act.ahead = head_code;
        act.ahead_gen = genPtr(fc.gen + 1);
    } else if (!fc.held) act.watch = 1;
}

export fn ekk_open(state: *serve.State, out: [*]u8, cap: usize, act: *serve.Action) void {
    enter("ekk_open");
    const fc = std.heap.c_allocator.create(FakeConn) catch @panic("out of memory");
    fc.* = .{ .id = next_conn.fetchAdd(1, .monotonic), .loop = loop_index, .dl = open_dl };
    state.* = fc;
    emit(.{ .kind = .open, .loop = fc.loop, .conn = fc.id });
    if (respond_on_open != 0) {
        fc.dl = write_code;
        fc.left = respond_on_open;
        return answerWriting(act, fc, 1, out, cap);
    }
    answerRecv(act, fc, room);
}

export fn ekk_recv(state: *serve.State, data: [*]const u8, n: usize, out: [*]u8, cap: usize, act: *serve.Action) void {
    enter("ekk_recv");
    const fc = connOf(state.*);
    emit(.{ .kind = .recv, .loop = fc.loop, .conn = fc.id, .n = @intCast(n), .byte = if (n > 0) data[0] else 0 });
    if (n == 0) {
        fc.dl = none_code;
        return answer(act, 2, 0);
    }
    if (respond != 0 and data[0] == 'R') {
        fc.dl = write_code;
        fc.gen += 1;
        fc.left = respond;
        fc.ahead = false;
        fc.held = false;
        return answerWriting(act, fc, 1, out, cap);
    }
    if (!recv_keeps) {
        fc.dl = recv_dl;
        fc.gen += 1;
    }
    answerRecv(act, fc, room);
}

export fn ekk_refused(state: *serve.State, _: [*]u8, _: usize, act: *serve.Action) void {
    enter("ekk_refused");
    const fc = connOf(state.*);
    emit(.{ .kind = .refused, .loop = fc.loop, .conn = fc.id });
    fc.dl = none_code;
    answer(act, 2, 0);
}

export fn ekk_fail(state: *serve.State, _: [*]u8, _: usize, act: *serve.Action) void {
    enter("ekk_fail");
    const fc = connOf(state.*);
    emit(.{ .kind = .fail, .loop = fc.loop, .conn = fc.id });
    fc.dl = none_code;
    answer(act, 2, 0);
}

/// The loop reports only its live arms (a retired one's callback calls
/// nothing): an expiry of any deadline and generation other than the
/// state's own pair or the head budget beside its send is a stale one the
/// loop should not have reported. The head beside a send closes when it is
/// incomplete; with `ahead_complete` its budget ends and the send goes on.
export fn ekk_expired(state: *serve.State, kind: u8, gen: serve.Gen, out: [*]u8, cap: usize, act: *serve.Action) void {
    enter("ekk_expired");
    const fc = connOf(state.*);
    const ahead = fc.ahead and kind == head_code and gen == genPtr(fc.gen + 1);
    if (!ahead and (fc.dl == none_code or kind != fc.dl or gen != genPtr(fc.gen))) @panic("the loop reported a stale expiry");
    emit(.{ .kind = .expired, .loop = fc.loop, .conn = fc.id, .n = if (ahead) fc.gen + 1 else fc.gen, .byte = kind });
    if (ahead and ahead_complete) {
        fc.ahead = false;
        fc.held = true;
        return answerWriting(act, fc, 3, out, cap);
    }
    fc.dl = none_code;
    fc.ahead = false;
    answer(act, 2, 0);
}

/// The loop reports readability only while the fake watches: while it
/// writes and no next request's byte has arrived yet.
export fn ekk_arrived(state: *serve.State, out: [*]u8, cap: usize, act: *serve.Action) void {
    enter("ekk_arrived");
    const fc = connOf(state.*);
    if (fc.dl != write_code or fc.ahead or fc.held) @panic("the loop reported readability the fake did not watch for");
    emit(.{ .kind = .arrived, .loop = fc.loop, .conn = fc.id, .n = fc.gen + 1 });
    fc.ahead = true;
    answerWriting(act, fc, 3, out, cap);
}

/// The send of `n` bytes of the response completed. At its end the
/// connection reads the next request, under the head budget that ran beside
/// the send when its byte arrived (the same pair: Conn.step_sent_handoff).
export fn ekk_sent(state: *serve.State, n: usize, out: [*]u8, cap: usize, act: *serve.Action) void {
    enter("ekk_sent");
    const fc = connOf(state.*);
    if (fc.dl != write_code or n == 0 or n > fc.asked) @panic("a send the fake did not ask for");
    if (due_on_sent) |conn| {
        due_on_sent = null;
        const arm = conn.arm orelse @panic("a send completion with no write deadline armed");
        conn.lp.loop.setTimer(&arm.timer, .{ .duration = .zero });
        due_injected = arm.timer.deadline;
    }
    fc.left -= n;
    if (report_sent) emit(.{ .kind = .sent, .loop = fc.loop, .conn = fc.id, .n = @intCast(n), .asked = @intCast(fc.asked), .left = @intCast(fc.left) });
    if (fc.left > 0) return answerWriting(act, fc, 1, out, cap);
    emit(.{ .kind = .written, .loop = fc.loop, .conn = fc.id, .n = fc.gen });
    if (fc.ahead) {
        fc.dl = head_code;
        fc.gen += 1;
        fc.ahead = false;
    } else fc.dl = none_code;
    answerRecv(act, fc, room);
}

export fn ekk_gen_eq(a: serve.Gen, b: serve.Gen) u8 {
    return @intFromBool(a == b);
}

export fn ekk_gen_free(_: serve.Gen) void {}

export fn ekk_free(state: serve.State) void {
    enter("ekk_free");
    const fc = connOf(state);
    emit(.{ .kind = .free, .loop = fc.loop, .conn = fc.id });
    std.heap.c_allocator.destroy(fc);
}

// The fake never asks to query, and these tests never call ekk_serve.
export fn ekk_answer(_: *serve.State, _: ?*anyopaque, _: [*]u8, _: usize, _: *serve.Action) void {
    @panic("ekk_answer: the fake never asks to query");
}
export fn ekk_string_cstr(_: *anyopaque) [*:0]const u8 {
    @panic("ekk_string_cstr: only ekk_serve calls it");
}
export fn ekk_pg_libpq_supported() c_int {
    @panic("ekk_pg_libpq_supported: only ekk_serve calls it");
}
export fn ekk_pg_libpq_version() c_int {
    @panic("ekk_pg_libpq_version: only ekk_serve calls it");
}
export fn ekk_thread_init() void {}
export fn ekk_thread_fini() void {}
export fn ekk_stop_signals() c_int {
    @panic("ekk_stop_signals: only ekk_serve calls it");
}
export fn ekk_fd_room(_: c_ulong) c_int {
    @panic("ekk_fd_room: only ekk_serve calls it");
}
export fn ekk_crash() void {
    @panic("ekk_crash: the crash points are off");
}

// pg.c: the loops run with no PostgreSQL connections (`pg_conns` 0) and the
// fake never asks to query, so the pool never calls these.
export fn ekk_pg_error(_: [*:0]const u8, _: [*:0]const u8) ?*anyopaque {
    @panic("ekk_pg_error");
}
export fn ekk_pg_abandoned(_: [*:0]const u8, _: [*:0]const u8) ?*anyopaque {
    @panic("ekk_pg_abandoned");
}
export fn ekk_pg_lost(_: ?*anyopaque) ?*anyopaque {
    @panic("ekk_pg_lost");
}
export fn ekk_pg_lost_sent(_: ?*anyopaque) ?*anyopaque {
    @panic("ekk_pg_lost_sent");
}
export fn ekk_query_timeout_ms(_: ?*anyopaque, _: c_uint, _: c_uint) c_uint {
    @panic("ekk_query_timeout_ms");
}
export fn ekk_pg_options(_: [*:0]const u8, _: c_uint, _: *?[*:0]u8) c_int {
    @panic("ekk_pg_options: only ekk_serve calls it");
}
export fn ekk_pg_start(_: [*:0]const u8, _: [*:0]const u8) ?*anyopaque {
    @panic("ekk_pg_start");
}
export fn ekk_pg_connect_poll(_: *anyopaque) c_int {
    @panic("ekk_pg_connect_poll");
}
export fn ekk_pg_socket(_: *anyopaque) c_int {
    @panic("ekk_pg_socket");
}
export fn ekk_pg_finish(_: *anyopaque) void {
    @panic("ekk_pg_finish");
}
export fn ekk_dup(_: c_int) c_int {
    @panic("ekk_dup");
}
export fn ekk_pg_send(_: *anyopaque, _: ?*anyopaque, _: *?*anyopaque) c_int {
    @panic("ekk_pg_send");
}
export fn ekk_pg_flush(_: *anyopaque) c_int {
    @panic("ekk_pg_flush");
}
export fn ekk_pg_consume(_: *anyopaque) c_int {
    @panic("ekk_pg_consume");
}
export fn ekk_pg_collect(_: *anyopaque, _: *?*anyopaque) c_int {
    @panic("ekk_pg_collect");
}
export fn ekk_query_drop(_: ?*anyopaque) void {
    @panic("ekk_query_drop");
}

// ---- events ----

fn openEvents() !void {
    if (c.pipe(&events) != 0) return error.Pipe;
}

fn closeEvents() void {
    for (events) |fd| _ = c.close(fd);
    events = .{ -1, -1 };
}

/// The next event if one has been written, without blocking.
fn pendingEvent() ?Event {
    var fds = [1]c.pollfd{.{ .fd = events[0], .events = c.POLL.IN, .revents = 0 }};
    const r = c.poll(&fds, 1, 0);
    if (r < 0) @panic("poll on the event pipe failed");
    if (r == 0) return null;
    return readEvent();
}

/// The next event, blocking until a loop writes one.
fn readEvent() Event {
    var e: Event = undefined;
    if (c.read(events[0], std.mem.asBytes(&e).ptr, @sizeOf(Event)) != @sizeOf(Event)) @panic("a short event read");
    return e;
}

fn printEvent(e: Event) void {
    std.debug.print(" {s}(loop {d} conn {d} n {d} byte {d} armed {} paused {} slots {d})", .{ @tagName(e.kind), e.loop, e.conn, e.n, e.byte, e.armed, e.paused, e.slots });
}

// ---- sockets ----

const Listener = struct {
    fd: c.fd_t,
    addr: union(enum) {
        tcp: c.sockaddr.in,
        /// The socket's path, in a directory of its own (`dir`).
        unix: struct { sa: c.sockaddr.un, dir: [dir_template.len:0]u8 },
    },

    const dir_template = "/tmp/lsrv-test.XXXXXX";

    /// The server's own nonblocking listening socket (serve.openListener) on
    /// 127.0.0.1 at a port the kernel picks.
    fn open() !Listener {
        const l = serve.openListener(0) orelse return error.OpenListener;
        var sa = std.mem.zeroes(c.sockaddr.in);
        sa.family = c.AF.INET;
        sa.port = std.mem.nativeToBig(u16, l.port);
        sa.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
        return .{ .fd = l.fd, .addr = .{ .tcp = sa } };
    }

    /// A nonblocking Unix-domain stream listening socket, in a new private
    /// directory under /tmp (short enough for `sun_path`). serve.zig's
    /// accept and connection path take its connections as they take TCP
    /// ones: it sets no socket option on them (TCP_NODELAY comes from
    /// `openListener`, which this listener does not use).
    fn openUnix() !Listener {
        var dir: [dir_template.len:0]u8 = dir_template.*;
        if (mkdtemp(&dir) == null) return error.MkdTemp;
        errdefer _ = c.rmdir(&dir);
        var sa = std.mem.zeroes(c.sockaddr.un);
        sa.family = c.AF.UNIX;
        const path = dir ++ "/s".*;
        @memcpy(sa.path[0..path.len], &path);
        const fd = socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = c.close(fd);
        if (c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) != 0) return error.Fcntl;
        if (c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.un)) != 0) return error.Bind;
        errdefer _ = c.unlink(@ptrCast(&sa.path));
        if (c.listen(fd, 16) != 0) return error.Listen;
        return .{ .fd = fd, .addr = .{ .unix = .{ .sa = sa, .dir = dir } } };
    }

    fn close(self: *Listener) void {
        _ = c.close(self.fd);
        switch (self.addr) {
            .tcp => {},
            .unix => |*u| {
                _ = c.unlink(@ptrCast(&u.sa.path));
                _ = c.rmdir(&u.dir);
            },
        }
    }

    /// A blocking client connected to the listener.
    pub fn connect(self: *const Listener) !c.fd_t {
        const fd = switch (self.addr) {
            .tcp => socket(c.AF.INET, c.SOCK.STREAM, 0),
            .unix => socket(c.AF.UNIX, c.SOCK.STREAM, 0),
        };
        if (fd < 0) return error.Socket;
        errdefer _ = c.close(fd);
        const r = switch (self.addr) {
            .tcp => |*sa| c.connect(fd, @ptrCast(sa), @sizeOf(c.sockaddr.in)),
            .unix => |*u| c.connect(fd, @ptrCast(&u.sa), @sizeOf(c.sockaddr.un)),
        };
        if (r != 0) return error.Connect;
        return fd;
    }
};

/// Waits until the kernel reports `fd` readable: a connection queued on a
/// listening socket, or bytes (or an end of input) on a connection.
pub fn awaitReadable(fd: c.fd_t) void {
    var fds = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    if (c.poll(&fds, 1, -1) != 1) @panic("poll for readiness failed");
}

fn send(fd: c.fd_t, bytes: []const u8) !void {
    if (c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.Write;
}

// ---- the shutdown on one loop, driven by the test's own thread ----

/// What `stopWrapped` saw of each connection's operation as the shutdown
/// began: the receive's completion phase, in the order of the loop's list.
var stop_phases: [8]ev.Completion.State.Phase = undefined;
var stop_nphases: usize = 0;
var stops: u32 = 0;

/// The loop's shutdown callback in the single-loop tests: serve.zig's
/// `stopCb`, run with `in_stop` set, after it notes the phase of every
/// receive in flight.
fn stopWrapped(loop: *ev.Loop, comp: *ev.Completion) void {
    const lp: *serve.LoopCtx = @ptrCast(@alignCast(comp.userdata.?));
    stop_nphases = 0;
    var it = lp.head;
    while (it) |conn| : (it = conn.next) {
        const op = conn.cur orelse continue;
        if (op.kind != .recv) continue;
        stop_phases[stop_nphases] = op.comp.recv.c.loadState().phase;
        stop_nphases += 1;
    }
    in_stop = true;
    serve.LoopCtx.stopCb(loop, comp);
    in_stop = false;
    stops += 1;
}

pub const Single = struct {
    lp: serve.LoopCtx,
    listener: Listener,
    log: [64]Event = undefined,
    n: usize = 0,

    /// On a TCP listener on 127.0.0.1.
    pub fn init(self: *Single, recv_room: usize) !void {
        return self.initOn(recv_room, .tcp);
    }

    fn initOn(self: *Single, recv_room: usize, family: enum { tcp, unix }) !void {
        try std.testing.expectEqual(@as(u32, 0), serve.slots_used.load(.monotonic));
        try openEvents();
        room = recv_room;
        open_dl = none_code;
        recv_dl = none_code;
        recv_keeps = false;
        respond = 0;
        ahead_complete = false;
        respond_on_open = 0;
        report_sent = false;
        due_on_sent = null;
        due_injected = null;
        serve.testing = .{};
        serve.accept_batch = serve.default_accept_batch;
        serve.budget_ms = .{ never, never, never, never };
        serve.drain_ms = never;
        stops = 0;
        serve.max_conns = 8;
        self.listener = switch (family) {
            .tcp => try Listener.open(),
            .unix => try Listener.openUnix(),
        };
        self.n = 0;
        self.lp = .{ .lfd = self.listener.fd };
        if (!serve.startLoop(&self.lp)) return error.StartLoop;
        self.lp.stop.c.callback = stopWrapped;
    }

    /// Ends whatever the test left of its loop, then frees it, so that a
    /// test that returned early (a failed `try`, before its stop and
    /// `finish`) leaves no connection, slot or deadline to the tests after
    /// it. It stops the loop if the stop has not run, makes every current
    /// deadline still waiting due (a send the fake asked for always runs
    /// under the write deadline, whose expiry closes it even when its client
    /// never reads),
    /// and runs the loop to its end. Something still open before that is a
    /// leak: it is logged at error level, which fails a test that passed
    /// (Zig's test runner reports a passing test that logged an error as a
    /// failure: lib/compiler/test_runner.zig `log`, counted in
    /// `log_err_count`; Maker/Step/Run.zig "logged {d} errors", Zig 0.17.1).
    /// For a test that failed, the line only adds to what it printed.
    /// ./cleanup-controls.sh checks both outcomes; run it for every change
    /// here and at each update of Zig.
    pub fn deinit(self: *Single) void {
        var open: u32 = 0;
        var it = self.lp.head;
        while (it) |conn| : (it = conn.next) open += 1;
        const slots = serve.slots_used.load(.monotonic);
        if (open != 0 or slots != 0) {
            std.log.err("the test left {d} connections open and {d} slots held; Single.deinit drains them", .{ open, slots });
            it = self.lp.head;
            while (it) |conn| : (it = conn.next) {
                const arm = conn.arm orelse continue;
                // Only a timer still waiting in the heap is moved: one that
                // has fired already has its callback on its way (zio's
                // `setTimer` asserts it is not re-armed mid-fire).
                const st = arm.timer.c.loadState();
                if (st.phase == .running and !arm.timer.c.has_result) self.lp.loop.setTimer(&arm.timer, .{ .duration = .zero });
            }
        }
        if (!self.lp.stopping) self.lp.stop.notify();
        // A drain still armed ends now, closing what is open.
        if (self.lp.drain_armed) {
            const st = self.lp.drain.c.loadState();
            if (st.phase == .running and !self.lp.drain.c.has_result) self.lp.loop.setTimer(&self.lp.drain, .{ .duration = .zero });
        }
        self.lp.loop.run() catch |err| std.debug.panic("Single.deinit could not run the loop to its end: {}", .{err});
        if (self.lp.head != null or serve.slots_used.load(.monotonic) != 0) @panic("Single.deinit left a connection or a slot behind");
        if (open != 0 or slots != 0) std.log.warn("Single.deinit drained them", .{});
        self.lp.loop.deinit();
        self.listener.close();
        closeEvents();
    }

    fn count(self: *const Single, kind: Kind) usize {
        var k: usize = 0;
        for (self.log[0..self.n]) |e| {
            if (e.kind == kind) k += 1;
        }
        return k;
    }

    fn dump(self: *const Single) void {
        std.debug.print("events ({d}):", .{self.n});
        for (self.log[0..self.n]) |e| printEvent(e);
        std.debug.print("\n", .{});
    }

    /// Takes the events written so far into the log.
    fn collect(self: *Single) void {
        while (pendingEvent()) |e| {
            if (self.n == self.log.len) @panic("the event log is full");
            self.log[self.n] = e;
            self.n += 1;
        }
    }

    /// Polls the loop without blocking until `want` events of `kind` have
    /// arrived in all, at most `max_steps` polls.
    pub fn stepUntil(self: *Single, kind: Kind, want: usize) !void {
        var step: usize = 0;
        while (true) : (step += 1) {
            self.collect();
            if (self.count(kind) >= want) return;
            if (step == max_steps) {
                std.debug.print("waited for {d} {s} events\n", .{ want, @tagName(kind) });
                self.dump();
                return error.EventNeverCame;
            }
            try self.lp.loop.poll(.zero);
        }
    }

    /// Runs the loop to its end: after the shutdown it has nothing left in
    /// flight, and the drain (`never` in these tests) was taken off when the
    /// last connection closed, or the run would not have returned.
    fn finish(self: *Single) !void {
        try self.lp.loop.run();
        try std.testing.expect(self.lp.head == null);
        try std.testing.expect(!self.lp.drain_armed);
        try std.testing.expectEqual(@as(u32, 0), serve.slots_used.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 1), stops);
    }
};

test "the shutdown cancels each receive in flight without calling back into the connections it traverses" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    var clients: [3]c.fd_t = undefined;
    for (&clients, 1..) |*cl, i| {
        cl.* = try s.listener.connect();
        awaitReadable(s.listener.fd);
        try s.stepUntil(.open, i);
    }
    defer for (clients) |cl| {
        _ = c.close(cl);
    };
    // Each connection now has a receive parked; stopCb cancels all three
    // (and the accept) while it walks the list. A callback from inside a
    // cancel would hit `enter` in the fake.
    s.lp.stop.notify();
    try s.stepUntil(.free, 3);
    try s.finish();
    try std.testing.expectEqual(@as(usize, 3), stop_nphases);
    for (stop_phases[0..stop_nphases]) |p| try std.testing.expectEqual(ev.Completion.State.Phase.running, p);
    // Each canceled receive came back once, as error.Canceled: refused, and
    // later freed.
    try std.testing.expectEqual(@as(usize, 3), s.count(.refused));
    try std.testing.expectEqual(@as(usize, 0), s.count(.fail));
    try std.testing.expectEqual(@as(usize, 0), s.count(.recv));
    for (s.log[0..s.n], 0..) |e, i| {
        if (e.kind != .open) continue;
        var refused_at: ?usize = null;
        var freed_at: ?usize = null;
        for (s.log[i + 1 .. s.n], i + 1..) |later, j| {
            if (later.conn != e.conn) continue;
            switch (later.kind) {
                .refused => {
                    try std.testing.expect(refused_at == null);
                    refused_at = j;
                },
                .free => {
                    try std.testing.expect(freed_at == null);
                    freed_at = j;
                },
                else => {},
            }
        }
        try std.testing.expect(refused_at.? < freed_at.?);
    }
}

test "startLoop joins its loop to no LoopGroup: the loop alone services its sockets" {
    // The loops share one listening socket, which is safe only while no zio
    // LoopGroup joins them (serve.zig, the comment above
    // `for (loops) |*lp| lp.* = .{ .lfd = lfd };` in `ekk_serve`). Checked
    // on the state `loop.init` left, not on how its options are spelled: in
    // the pinned zio (53ed3c377317) a loop given no `loop_group` uses its own
    // `internal_loop_group`, and every loop of a group counts in its `loops`
    // (src/ev/loop.zig:515-516, 559-563, 574); the registration table its
    // sockets park on is that group's (loop.zig:582). Recheck at each update
    // of zio, with `pg.ownLoop`, the runtime backstop in every callback.
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    try std.testing.expect(s.lp.loop.loop_group == &s.lp.loop.internal_loop_group);
    try std.testing.expectEqual(@as(u32, 1), s.lp.loop.internal_loop_group.loops.load(.monotonic));
    s.lp.stop.notify();
    try s.finish();
}

/// Whether `name`, the value of an identifier or a string literal, is one
/// of zio's names for grouping loops.
fn namesLoopGroup(name: []const u8) bool {
    return std.mem.eql(u8, name, "loop_group") or std.mem.eql(u8, name, "LoopGroup");
}

/// The value of a string literal token (quotes included), escapes decoded.
fn literalValue(text: []const u8) ![]u8 {
    return std.zig.string_literal.parseAlloc(std.testing.allocator, text);
}

test "the transport's Zig sources never name zio's loop grouping" {
    // The test above checks the loop `startLoop` sets up; this one reads the
    // transport's Zig sources for a grouping spelled anywhere else (a second
    // `loop.init`, an options value built elsewhere). It is lexical: no
    // identifier (plain or `@"..."`), string literal (as in
    // `@field(options, "...")`) or line of a multiline string has the value
    // `loop_group` or `LoopGroup`, escapes decoded. Comments, which name the
    // rule, are ignored. Every `@import` must name `std`, `zio` or a file
    // scanned here, so a new module of the transport fails until it is
    // added; Zig takes `@import`'s operand only as a string literal (Zig
    // 0.17.1: "@import operand must be a string literal", also for
    // `@import(("..."))`), so each is read as `@import("...")`. It does not
    // evaluate code: a name computed at comptime is not seen, nor zio's own
    // `Runtime`, which groups its executors' loops itself
    // (src/runtime.zig:702, 1807 at the pin); a callback run on another
    // loop still meets `pg.ownLoop`.
    const sources = [_]struct { name: []const u8, text: [:0]const u8 }{
        .{ .name = "serve.zig", .text = @embedFile("serve.zig") },
        .{ .name = "pg.zig", .text = @embedFile("pg.zig") },
    };
    const a = std.testing.allocator;
    for (sources) |src| {
        var tokens = std.zig.Tokenizer.init(src.text);
        // The tokens still owed by an `@import`: its parenthesis, its path.
        var import_step: enum { none, paren, path } = .none;
        while (true) {
            const t = tokens.next();
            if (t.tag == .eof) break;
            const text = src.text[t.loc.start..t.loc.end];
            const value: ?[]u8 = switch (t.tag) {
                .identifier => if (text[0] == '@') try literalValue(text[1..]) else try a.dupe(u8, text),
                .string_literal => try literalValue(text),
                .multiline_string_literal_line => try a.dupe(u8, std.mem.trimEnd(u8, text[2..], "\r\n")),
                else => null,
            };
            defer if (value) |v| a.free(v);
            if (value) |v| if (namesLoopGroup(v)) {
                std.debug.print("{s} names {s} at byte {d}\n", .{ src.name, text, t.loc.start });
                return error.LoopGroupNamed;
            };
            switch (import_step) {
                .none => if (t.tag == .builtin and std.mem.eql(u8, text, "@import")) {
                    import_step = .paren;
                },
                .paren => import_step = .path,
                .path => {
                    import_step = .none;
                    const path = value.?;
                    var known = std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "zio");
                    for (sources) |other| known = known or std.mem.eql(u8, path, other.name);
                    if (!known) {
                        std.debug.print("{s} imports {s}, which this test does not scan\n", .{ src.name, path });
                        return error.UnscannedImport;
                    }
                },
            }
        }
    }
}

test "the loops run on the backend the build chose: kqueue on macOS, epoll or io_uring on Linux" {
    // A run of these tests on Linux (./linux-check.sh) is a run on the
    // backend named by -Dlinux-backend (build.zig, item wi7efy).
    switch (@import("builtin").os.tag) {
        .macos => try std.testing.expect(ev.backend == .kqueue),
        .linux => try std.testing.expectEqualStrings(@tagName(build_options.linux_backend), @tagName(ev.backend)),
        else => return error.UncheckedOs,
    }
}

/// io_uring, a completion backend: zio queues an operation started in a
/// callback as an SQE, and the kernel first runs it at the next poll's
/// `io_uring_enter`, which comes after that poll's timer check
/// (backends/linux/io_uring.zig `submitInner`; loop.zig `Loop.poll`). On
/// kqueue and epoll zio tries it at `loop.add` (src/ev/sockreg.zig
/// `submitIo`). Two receive tests below state what each does.
const completion_backend = ev.backend == .io_uring;

test "an accepted connection has TCP_NODELAY, inherited from the listening socket" {
    // serve.zig sets TCP_NODELAY only on the listener (openListener); the
    // kernel copies it to each accepted socket. Checked on macOS and, through
    // ./linux-check.sh, on Linux (item ogcdwm).
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const accepted = s.lp.head orelse return error.NoConnection;
    var nodelay: c_int = 0;
    try zio.os.net.getsockopt(accepted.fd, zio.os.net.IPPROTO.TCP, zio.os.posix.TCP.NODELAY, std.mem.asBytes(&nodelay));
    try std.testing.expect(nodelay != 0);
    s.lp.stop.notify();
    try s.stepUntil(.free, 1);
    try s.finish();
}

test "a receive whose result is queued when the shutdown cancels it is dispatched once, with that result" {
    var s: Single = undefined;
    // One byte per receive: "ab" takes two receives.
    try s.init(1);
    defer s.deinit();
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const conn = s.log[0].conn;
    // Both bytes, written at once, are readable at the server's end, and the
    // stop is notified, before the loop polls again. In that one poll the
    // parked receive returns "a" and the stop completes, in that order. The
    // callback for "a" starts the next receive. On kqueue and epoll zio tries
    // it at once, it finds "b", and its completion is queued with its result
    // before stopCb runs: the cancel finds it completed, which `stop_phases`
    // shows. On io_uring it is an SQE not yet submitted (still running) when
    // stopCb cancels it; the next enter submits both, and the receive is
    // dispatched once, with "b" or as canceled, as the kernel orders them.
    try send(cl, "ab");
    awaitReadable(s.lp.head.?.fd);
    s.lp.stop.notify();
    try s.stepUntil(.free, 1);
    try s.finish();
    try std.testing.expectEqual(@as(usize, 1), stop_nphases);
    const phase: ev.Completion.State.Phase = if (completion_backend) .running else .completed;
    try std.testing.expectEqual(phase, stop_phases[0]);
    // "b" arrives as received (not error.Canceled); the receive asked after it
    // is declined (refused) because the shutdown has begun.
    const Want = struct { kind: Kind, byte: u8 = 0 };
    const received = [_]Want{
        .{ .kind = .open },
        .{ .kind = .recv, .byte = 'a' },
        .{ .kind = .recv, .byte = 'b' },
        .{ .kind = .refused },
        .{ .kind = .free },
    };
    // The canceled receive is not reported: the connection closes.
    const canceled = [_]Want{
        .{ .kind = .open },
        .{ .kind = .recv, .byte = 'a' },
        .{ .kind = .free },
    };
    const want: []const Want = if (completion_backend and s.n == canceled.len) &canceled else &received;
    if (s.n != want.len) {
        s.dump();
        return error.UnexpectedEvents;
    }
    for (want, s.log[0..s.n]) |w, e| {
        try std.testing.expectEqual(w.kind, e.kind);
        try std.testing.expectEqual(conn, e.conn);
        if (w.kind == .recv) {
            try std.testing.expectEqual(@as(u32, 1), e.n);
            try std.testing.expectEqual(w.byte, e.byte);
        }
    }
}

// ---- deadlines ----

/// A budget no test reaches: each deadline test makes its timers due
/// itself, and the others arm none.
const never: u32 = 1 << 31;
/// A budget whose timer is due when it is armed.
const due_at_once: u32 = 0;

/// Moves the connection's current deadline to now (a test hook): its timer
/// is due at the loop's next timer check, which comes before its I/O in
/// every poll (zio 53ed3c377317, `Loop.poll`: `checkTimers`, then the
/// backend, then the queued completions).
fn dueNow(s: *Single) void {
    const conn = s.lp.head.?;
    s.lp.loop.setTimer(&conn.arm.?.timer, .{ .duration = .zero });
}

/// Checks that the log is exactly `want` (kinds, and for receives and
/// expiries their bytes or deadline and generation), all of one connection.
fn expectLog(s: *const Single, want: []const Event) !void {
    if (s.n != want.len) {
        s.dump();
        return error.UnexpectedEvents;
    }
    for (want, s.log[0..s.n]) |w, e| {
        try std.testing.expectEqual(w.kind, e.kind);
        try std.testing.expectEqual(s.log[0].conn, e.conn);
        if (w.kind == .recv or w.kind == .expired) {
            try std.testing.expectEqual(w.n, e.n);
            try std.testing.expectEqual(w.byte, e.byte);
        }
    }
}

test "a deadline whose timer ends closes the connection, and the receive in flight is not reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    open_dl = head_code;
    serve.budget_ms[head_code - 1] = due_at_once;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .expired, .n = 0, .byte = head_code }, .{ .kind = .free } });
    // The client sees the close.
    var b: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(cl, &b, 1));
    s.lp.stop.notify();
    try s.finish();
}

test "a receive within one period keeps its armed timer and due time, and that timer's expiry is reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    open_dl = head_code;
    recv_keeps = true;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const conn = s.lp.head.?;
    const arm = conn.arm.?;
    const due = arm.timer.deadline;
    try send(cl, "a");
    try s.stepUntil(.recv, 1);
    // The same deadline and generation: the arm and its due time stay, so
    // a peer sending a byte at a time cannot extend the period.
    try std.testing.expect(conn.arm.? == arm);
    try std.testing.expect(!arm.retired);
    try std.testing.expectEqual(due, arm.timer.deadline);
    dueNow(&s);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .recv, .n = 1, .byte = 'a' }, .{ .kind = .expired, .n = 0, .byte = head_code }, .{ .kind = .free } });
    s.lp.stop.notify();
    try s.finish();
}

test "an expiry the loop runs before a ready receive closes, and the bytes are not reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    open_dl = head_code;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    // The receive is parked; its bytes become readable and its deadline
    // due before the loop polls again. That poll runs the timer first:
    // the expiry cancels the receive, whose result only leads to the close.
    try send(cl, "a");
    awaitReadable(s.lp.head.?.fd);
    dueNow(&s);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .expired, .n = 0, .byte = head_code }, .{ .kind = .free } });
    s.lp.stop.notify();
    try s.finish();
}

test "a receive the loop runs before a due expiry wins: that expiry is stale and not reported" {
    var s: Single = undefined;
    // One byte per receive: "ab" takes two receives.
    try s.init(1);
    defer s.deinit();
    open_dl = head_code;
    recv_dl = idle_code;
    serve.budget_ms[idle_code - 1] = due_at_once;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    // In one poll the parked receive returns "a"; its callback arms the
    // idle deadline of generation 1, due at once, and starts the next
    // receive, which finds "b" and is queued with its result. The queued
    // completion runs before the next timer check, so "b" is reported and
    // generation 1's due timer is replaced by generation 2's, whose expiry
    // the fake checks is current.
    //
    // On io_uring that next receive is an SQE the next poll submits only
    // after its timer check (`completion_backend`), so generation 1's expiry
    // runs first: it is current, it closes, and "b" is not reported.
    try send(cl, "ab");
    awaitReadable(s.lp.head.?.fd);
    try s.stepUntil(.free, 1);
    if (completion_backend) try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'a' },
        .{ .kind = .expired, .n = 1, .byte = idle_code },
        .{ .kind = .free },
    }) else try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'a' },
        .{ .kind = .recv, .n = 1, .byte = 'b' },
        .{ .kind = .expired, .n = 2, .byte = idle_code },
        .{ .kind = .free },
    });
    s.lp.stop.notify();
    try s.finish();
}

// ---- a pipelined request's head budget beside a blocked response ----

/// A response larger than the socket buffers seen in the runs so far on
/// both ends: while the client does not read, its sends fill them and one
/// parks. On TCP that is not guaranteed: loopback may keep moving bytes
/// into the client's receive buffer and freeing room in the server's send
/// buffer after a send parked, so it may become ready with no read by the
/// client, and Linux autotunes a send buffer it was not given past 1 MiB
/// (tcp_wmem). The tests that need a send to stay parked use a Unix-domain
/// pair; the TCP tests that wait for a parked send ask for small buffers.
const response_len: usize = 1 << 20;
/// The size the tests ask for the server's send buffer (and on TCP the
/// client's receive buffer). The kernel need not grant it, and no test
/// checks what it granted: on macOS getsockopt read 314352 for a client's
/// SO_RCVBUF set to this before connect (item znioju), and Linux doubles a
/// requested SO_SNDBUF (socket(7)). A test whose premise is a parked or
/// partial send asserts that event itself.
const small_buffer: c_int = 4096;

fn setBuffer(fd: c.fd_t, opt: u32) !void {
    if (c.setsockopt(fd, c.SOL.SOCKET, opt, std.mem.asBytes(&small_buffer), @sizeOf(c_int)) != 0) return error.SetSockOpt;
}

/// Polls the loop until the readiness poll is in flight beside a parked
/// send, at most `max_steps` polls.
fn stepUntilPolling(s: *Single) !void {
    const conn = s.lp.head.?;
    var step: usize = 0;
    while (!conn.polling) : (step += 1) {
        if (step == max_steps) {
            s.dump();
            return error.PollNeverStarted;
        }
        try s.lp.loop.poll(.zero);
        s.collect();
    }
}

/// Connects a client to the test's listener (on TCP asking for a
/// `small_buffer` receive buffer), has it send a request ('R'), and steps
/// the loop until the fake has started the response of `len` bytes, its
/// send on a server socket asked for a `small_buffer` send buffer. The
/// kernel may grant other sizes.
fn requestResponse(s: *Single, len: usize) !c.fd_t {
    respond = len;
    recv_keeps = true;
    const cl = switch (s.listener.addr) {
        .tcp => |*sa| tcp: {
            const fd = socket(c.AF.INET, c.SOCK.STREAM, 0);
            if (fd < 0) return error.Socket;
            errdefer _ = c.close(fd);
            try setBuffer(fd, c.SO.RCVBUF);
            if (c.connect(fd, @ptrCast(sa), @sizeOf(c.sockaddr.in)) != 0) return error.Connect;
            break :tcp fd;
        },
        .unix => try s.listener.connect(),
    };
    errdefer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    try setBuffer(s.lp.head.?.fd, c.SO.SNDBUF);
    try send(cl, "R");
    try s.stepUntil(.recv, 1);
    return cl;
}

/// `requestResponse` with a blocked response; then the client sends part of
/// a next request's head ("G"), which the readiness poll beside the send
/// reports.
fn pipelinedBehindResponse(s: *Single) !c.fd_t {
    const cl = try requestResponse(s, response_len);
    errdefer _ = c.close(cl);
    try stepUntilPolling(s);
    try send(cl, "G");
    try s.stepUntil(.arrived, 1);
    return cl;
}

/// The most rounds of draining the client and polling the loop until the
/// response's last send completed.
const max_drain = 100_000;

/// Reads whatever the client has, without blocking, and polls the loop,
/// until the fake has seen the response's last send. Returns the bytes the
/// client read.
fn drainUntilWritten(s: *Single, cl: c.fd_t) !usize {
    var buf: [65536]u8 = undefined;
    var got: usize = 0;
    var round: usize = 0;
    while (s.count(.written) == 0) : (round += 1) {
        if (round == max_drain) {
            s.dump();
            return error.ResponseNeverWritten;
        }
        const r = c.recv(cl, &buf, buf.len, c.MSG.DONTWAIT);
        if (r > 0) {
            got += @intCast(r);
        } else if (r == 0) {
            s.dump();
            return error.ClientEndedBeforeWritten;
        } else if (c.errno(r) != .AGAIN) {
            return error.ClientRead;
        }
        try s.lp.loop.poll(.zero);
        s.collect();
    }
    return got;
}

test "the shutdown's drain ends with a send waiting in the kernel: the send is canceled, unreported, and the connection closes" {
    // On a Unix-domain pair whose client never reads, so the parked send
    // stays in the kernel until the drain ends (see the write deadline's
    // test of the same kind, "a write deadline that ends while its send
    // waits in the kernel ..."): on loopback TCP it may become ready on its
    // own, and the drain would then find nothing to cancel.
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    respond_on_open = response_len;
    const cl = try s.listener.connect();
    // Closed before `s.deinit` runs (defers run last first): should a check
    // below fail with the send still parked, the close ends it.
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    // The readiness poll in flight is the event that the send waits in the
    // kernel (serve.zig starts it only beside a parked send, `sendParked`).
    try stepUntilPolling(&s);
    const conn = s.lp.head.?;
    s.lp.stop.notify();
    var step: usize = 0;
    while (stops == 0) : (step += 1) {
        if (step == max_steps) return error.StopNeverRan;
        try s.lp.loop.poll(.zero);
    }
    // The send goes on after the stop, under the drain, still in the kernel.
    try std.testing.expect(s.lp.drain_armed);
    try spyOnSendCompletion(conn);
    try std.testing.expect(!writableNow(conn.fd));
    s.lp.loop.setTimer(&s.lp.drain, .{ .duration = .zero });
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .free },
    });
    // The drain's end canceled the send: its one completion carried
    // error.Canceled, to the closing connection, and wrote nothing.
    try std.testing.expectEqual(@as(u32, 1), spied.calls);
    try std.testing.expect(spied.closing);
    try std.testing.expect(spied.canceled);
    try std.testing.expect(!spied.failed);
    try std.testing.expectEqual(@as(usize, 0), spied.wrote);
    try s.finish();
}

test "a partial pipelined head behind a blocked response: finishing the response neither starts nor resets its budget" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    const cl = try pipelinedBehindResponse(&s);
    defer _ = c.close(cl);
    const conn = s.lp.head.?;
    // The head budget runs beside the send from the byte's arrival, in the
    // generation after the response's (Conn.Phase.ahead); the poll is done.
    const write_arm = conn.arm.?;
    try std.testing.expectEqual(write_code, write_arm.kind);
    try std.testing.expect(write_arm.gen == genPtr(1));
    const head_arm = conn.ahead_arm.?;
    try std.testing.expectEqual(head_code, head_arm.kind);
    try std.testing.expect(head_arm.gen == genPtr(2));
    try std.testing.expect(!conn.polling);
    const due = head_arm.timer.deadline;
    _ = try drainUntilWritten(&s, cl);
    // The response is sent whole: the same arm, with the same due time, is
    // now the reading phase's own deadline; the write deadline is gone.
    try std.testing.expect(conn.arm.? == head_arm);
    try std.testing.expect(!head_arm.retired);
    try std.testing.expectEqual(due, head_arm.timer.deadline);
    try std.testing.expect(conn.ahead_arm == null);
    // The receive after the response returns "G", within that period.
    try s.stepUntil(.recv, 2);
    try std.testing.expect(conn.arm.? == head_arm);
    try std.testing.expectEqual(due, head_arm.timer.deadline);
    dueNow(&s);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'R' },
        .{ .kind = .arrived },
        .{ .kind = .written },
        .{ .kind = .recv, .n = 1, .byte = 'G' },
        .{ .kind = .expired, .n = 2, .byte = head_code },
        .{ .kind = .free },
    });
    s.lp.stop.notify();
    try s.finish();
}

test "a partial pipelined head whose budget ends while its response is still blocked closes, and the send is not reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    const cl = try pipelinedBehindResponse(&s);
    defer _ = c.close(cl);
    const conn = s.lp.head.?;
    s.lp.loop.setTimer(&conn.ahead_arm.?.timer, .{ .duration = .zero });
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'R' },
        .{ .kind = .arrived },
        .{ .kind = .expired, .n = 2, .byte = head_code },
        .{ .kind = .free },
    });
    s.lp.stop.notify();
    try s.finish();
}

test "a complete pipelined head whose budget ends while its response is still blocked: the budget ends and the send goes on" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    ahead_complete = true;
    const cl = try pipelinedBehindResponse(&s);
    defer _ = c.close(cl);
    const conn = s.lp.head.?;
    const write_arm = conn.arm.?;
    s.lp.loop.setTimer(&conn.ahead_arm.?.timer, .{ .duration = .zero });
    try s.stepUntil(.expired, 1);
    // Only the head budget's arm is gone; the write deadline's arm stays,
    // the send is still in flight, and nothing watches any more.
    try std.testing.expect(conn.ahead_arm == null);
    try std.testing.expect(conn.arm.? == write_arm);
    try std.testing.expect(!write_arm.retired);
    try std.testing.expect(conn.cur.?.kind == .send);
    try std.testing.expect(!conn.polling and !conn.watching);
    _ = try drainUntilWritten(&s, cl);
    try s.stepUntil(.recv, 2);
    _ = c.shutdown(cl, c.SHUT.WR);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'R' },
        .{ .kind = .arrived },
        .{ .kind = .expired, .n = 2, .byte = head_code },
        .{ .kind = .written },
        .{ .kind = .recv, .n = 1, .byte = 'G' },
        .{ .kind = .recv, .n = 0, .byte = 0 },
        .{ .kind = .free },
    });
    s.lp.stop.notify();
    try s.finish();
}

test "a response sent at once starts no poll, and the receive after it reports what arrived" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    // Small enough for the socket buffers: the send completes when it is
    // submitted, so the fake's watch starts no poll.
    const cl = try requestResponse(&s, 16);
    defer _ = c.close(cl);
    const conn = s.lp.head.?;
    try s.stepUntil(.written, 1);
    try std.testing.expectEqual(@as(u64, 0), conn.polls);
    _ = c.shutdown(cl, c.SHUT.WR);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'R' },
        .{ .kind = .written },
        .{ .kind = .recv, .n = 0, .byte = 0 },
        .{ .kind = .free },
    });
    s.lp.stop.notify();
    try s.finish();
}

test "a write deadline that ends while a send the loop performed waits for its turn closes, and the send is not reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    respond_on_open = 16;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    // The open's callback started the response; serve.zig's own try of its
    // send wrote it (16 bytes fit the socket buffer), and its result waits
    // in the loop's ready list for the next turn (`Conn.startSend`). That
    // turn checks the timers first (`dueNow`): the expiry finds a send that
    // has completed, so it cancels nothing, and the result's delivery closes.
    const conn = s.lp.head.?;
    try std.testing.expect(conn.cur.?.kind == .wrote);
    try std.testing.expectEqual(@as(?usize, 16), conn.cur.?.wrote);
    try std.testing.expect(s.lp.ready_head == conn);
    try std.testing.expectEqual(@as(u64, 0), conn.polls);
    dueNow(&s);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .expired, .n = 0, .byte = write_code },
        .{ .kind = .free },
    });
    try std.testing.expect(s.lp.ready_head == null);
    s.lp.stop.notify();
    try s.finish();
}

test "over TCP, a response larger than the send buffer reaches a reading client whole, through a parked send" {
    // The TCP counterpart of the Unix-domain tests of parked and partial
    // sends below (item emb2ob): a Unix-domain pair makes those tests'
    // premises stable, and their coverage does not establish TCP's. This
    // one asserts its own premise, a send parked while the client does not
    // read, by its event (the readiness poll beside it; with the small
    // buffers `requestResponse` asks for, it came in the runs on macOS and
    // Linux), and checks that once the client reads, the fake hears of the
    // response's last send and the
    // client gets the whole response, no more, before the close. (Each send
    // is not reported: a 1 MiB response takes more of them than the log
    // holds.)
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    const cl = try requestResponse(&s, response_len);
    defer _ = c.close(cl);
    try stepUntilPolling(&s);
    var got = try drainUntilWritten(&s, cl);
    _ = c.shutdown(cl, c.SHUT.WR);
    try s.stepUntil(.free, 1);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = c.read(cl, &buf, buf.len);
        if (r < 0) return error.ClientRead;
        if (r == 0) break;
        got += @intCast(r);
    }
    try std.testing.expectEqual(response_len, got);
    try std.testing.expectEqual(@as(usize, 1), s.count(.written));
    try std.testing.expectEqual(@as(usize, 0), s.count(.expired) + s.count(.fail));
    s.lp.stop.notify();
    try s.finish();
}

test "a response whose write deadline ends before any next byte arrives closes once the canceled poll completed" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    const cl = try requestResponse(&s, response_len);
    defer _ = c.close(cl);
    try stepUntilPolling(&s);
    const conn = s.lp.head.?;
    try std.testing.expect(conn.watching and !conn.poll_stale);
    try std.testing.expect(conn.ahead_arm == null);
    // The expiry asks to cancel the parked send, unless the kernel let it
    // complete first (loopback may still free room in the send buffer
    // after the send parked); its one completion reaches a closing
    // connection and is not reported.
    try spyOnSend(conn);
    dueNow(&s);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'R' },
        .{ .kind = .expired, .n = 1, .byte = write_code },
        .{ .kind = .free },
    });
    try expectSendClosed();
    s.lp.stop.notify();
    try s.finish();
}

test "a send that fails while the poll beside it is in flight closes only after the poll's completion" {
    // On a Unix-domain pair, so that a send parks before the client reads
    // and stays parked until it does (on loopback TCP Linux's autotuned send
    // buffer took the whole response with no send parked; item emb2ob).
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    defer serve.testing = .{};
    respond_on_open = response_len;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    // The client reads nothing: the sends complete at once until the
    // buffer fills, and the one that parks has the poll beside it.
    try stepUntilPolling(&s);
    const conn = s.lp.head.?;
    // From now on every completed send is reported as failed: once the
    // client reads, the parked send completes, and its failure closes in
    // the callback that cancels the poll, so the close must wait for that
    // poll's completion (`close_pending`).
    serve.testing.fail_every = 1;
    var buf: [65536]u8 = undefined;
    var round: usize = 0;
    while (s.count(.fail) == 0) : (round += 1) {
        if (round == max_drain) {
            s.dump();
            return error.NoSendFailed;
        }
        _ = c.recv(cl, &buf, buf.len, c.MSG.DONTWAIT);
        try s.lp.loop.poll(.zero);
        s.collect();
    }
    try std.testing.expect(conn.close_pending and conn.polling and conn.poll_stale);
    try std.testing.expect(conn.cur == null);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .fail }, .{ .kind = .free } });
    s.lp.stop.notify();
    try s.finish();
}

// ---- a write deadline against a partial send ----

/// The send in flight, which waits in the kernel: serve.zig's own try of it
/// returned EAGAIN, and it handed it to zio (`startSend`).
fn expectParkedSend(conn: *serve.Conn) !void {
    const op = conn.cur orelse return error.NoOperation;
    try std.testing.expect(op.kind == .send);
    try std.testing.expectEqual(ev.Completion.State.Phase.running, op.comp.send.c.loadState().phase);
}

/// The most client reads `drainUntilWritable` makes.
const max_reads = 1000;

/// Until the kernel reports the server's socket `fd` writable, reads what
/// reaches the client and adds it to `got`; it waits for whichever comes
/// first. On the Unix-domain pairs that use it the room comes from these
/// reads alone. The loop does not poll meanwhile.
fn drainUntilWritable(cl: c.fd_t, fd: c.fd_t, got: *usize) !void {
    var buf: [65536]u8 = undefined;
    var reads: usize = 0;
    while (true) : (reads += 1) {
        if (reads == max_reads) return error.NeverWritable;
        var fds = [2]c.pollfd{
            .{ .fd = fd, .events = c.POLL.OUT, .revents = 0 },
            .{ .fd = cl, .events = c.POLL.IN, .revents = 0 },
        };
        if (c.poll(&fds, 2, -1) < 1) @panic("poll for writability or bytes failed");
        if (fds[0].revents & c.POLL.OUT != 0) return;
        const r = c.recv(cl, &buf, buf.len, c.MSG.DONTWAIT);
        if (r <= 0) return error.ClientReadNothing;
        got.* += @intCast(r);
    }
}

/// The bytes the fake heard of as sent.
fn reportedSent(s: *const Single) usize {
    var total: usize = 0;
    for (s.log[0..s.n]) |e| {
        if (e.kind == .sent) total += e.n;
    }
    return total;
}

/// The first `sent` event at or after log index `from`.
fn sentFrom(s: *const Single, from: usize) !Event {
    for (s.log[from..s.n]) |e| {
        if (e.kind == .sent) return e;
    }
    return error.NoSentEvent;
}

/// A response blocked behind the server's small send buffer, with one real
/// partial send completed: the send that parked completes once the client reads,
/// writing fewer bytes than it was asked to while bytes of the response
/// remain. That completion keeps the write deadline's arm, with the due
/// time it was armed with. Returns with the next send parked and its
/// readiness poll beside it.
///
/// On a Unix-domain pair (the test's `initOn(.unix)`): its room is freed
/// only by the client's reads, so the send stays parked until
/// `drainUntilWritable`, and the next one parks again while the client does
/// not read. That the completion is partial is not derived from a buffer
/// size the kernel reports (macOS and Linux size it differently; item
/// emb2ob): the `sent` event itself is checked to have written less than it
/// was asked, with bytes left. The small send buffer `requestResponse` asks
/// for is what made it partial in the runs on macOS and Linux.
const PartialSend = struct { cl: c.fd_t, arm: *serve.Arm, due: @FieldType(ev.Timer, "deadline"), got: usize };

fn partialSend(s: *Single) !PartialSend {
    report_sent = true;
    const cl = try requestResponse(s, response_len);
    errdefer _ = c.close(cl);
    try stepUntilPolling(s);
    const conn = s.lp.head.?;
    try expectParkedSend(conn);
    const arm = conn.arm.?;
    try std.testing.expectEqual(write_code, arm.kind);
    const due = arm.timer.deadline;
    var got: usize = 0;
    const from = s.n;
    try drainUntilWritable(cl, conn.fd, &got);
    try s.stepUntil(.sent, s.count(.sent) + 1);
    const e = try sentFrom(s, from);
    // The positive event: this completion wrote part of what it asked.
    try std.testing.expect(e.n < e.asked);
    try std.testing.expect(e.left > 0);
    try std.testing.expect(conn.arm.? == arm);
    try std.testing.expect(!arm.retired);
    try std.testing.expectEqual(due, arm.timer.deadline);
    try expectParkedSend(conn);
    try std.testing.expect(conn.polling and conn.watching);
    return .{ .cl = cl, .arm = arm, .due = due, .got = got };
}

/// The send in flight at the expiry, seen by two spies in front of
/// serve.zig's callbacks: `timerSpy` around the write deadline's timer
/// callback (whether the send was still in the kernel when the expiry ran,
/// and whether the cancel was asked after it), `sendSpy` before the send's
/// (what its one completion carried). zio's `Loop.cancel`
/// (pinned 53ed3c377317, src/ev/loop.zig) says "the completion's callback
/// will still be invoked when the operation completes (either with
/// error.Canceled or its natural result)", and a cancel of a completion
/// already completed is a no-op (src/ev/completion.zig, `requestCancel`:
/// "Completed/dead: too late, no-op"). serve.zig's `closing` reports
/// neither result to Lean.
/// Which of the two a send in flight at the expiry gets depends on whether
/// the kernel let it complete before the expiry's poll, which the tests
/// force only where they say so.
const SpiedSend = struct {
    /// `timerSpy`: calls; the send was running (parked) as the expiry
    /// began; after it, a cancel was asked and the connection closes.
    expiries: u32 = 0,
    running_at_expiry: bool = false,
    cancel_after_expiry: bool = false,
    closing_after_expiry: bool = false,
    /// `sendSpy`: calls; the connection closes; the result.
    calls: u32 = 0,
    closing: bool = false,
    canceled: bool = false,
    /// An error other than error.Canceled: neither outcome the tests allow.
    failed: bool = false,
    wrote: usize = 0,
};
var spied: SpiedSend = .{};
var spied_callback: ?*const ev.Completion.CallbackFn = null;
var spied_timer_callback: ?*const ev.Completion.CallbackFn = null;
var spied_conn: ?*serve.Conn = null;
var spied_send: ?*ev.Completion = null;

/// The write deadline's timer callback, with the send's state read before
/// and after it. The send's completion is queued, not run, inside it
/// (`defer_callback`), so it is still the connection's afterwards.
fn timerSpy(loop: *ev.Loop, comp: *ev.Completion) void {
    const send_c = spied_send.?;
    spied.expiries += 1;
    spied.running_at_expiry = send_c.loadState().phase == .running;
    spied_timer_callback.?(loop, comp);
    spied.cancel_after_expiry = send_c.loadState().cancel_requested;
    spied.closing_after_expiry = spied_conn.?.closing;
}

fn sendSpy(loop: *ev.Loop, comp: *ev.Completion) void {
    const send_op: *ev.NetSend = @fieldParentPtr("c", comp);
    spied.calls += 1;
    spied.closing = spied_conn.?.closing;
    if (send_op.getResult()) |n| {
        spied.wrote = n;
    } else |err| {
        if (err == error.Canceled) spied.canceled = true else spied.failed = true;
    }
    spied_callback.?(loop, comp);
}

/// Puts `sendSpy` in front of the callback of the parked send in flight.
fn spyOnSendCompletion(conn: *serve.Conn) !void {
    try expectParkedSend(conn);
    const comp = &conn.cur.?.comp.send.c;
    spied = .{};
    spied_conn = conn;
    spied_send = comp;
    spied_callback = comp.callback;
    comp.callback = sendSpy;
}

/// `spyOnSendCompletion`, and `timerSpy` in front of the write deadline's
/// callback.
fn spyOnSend(conn: *serve.Conn) !void {
    try spyOnSendCompletion(conn);
    const timer = &conn.arm.?.timer.c;
    spied_timer_callback = timer.callback;
    timer.callback = timerSpy;
}

/// The expiry ran once and closed; it asked to cancel the send if that
/// send was still in the kernel (a cancel of a completed one is a no-op);
/// the send then completed once, to the closing connection, canceled only
/// if it was still in the kernel at the expiry.
fn expectSendClosed() !void {
    try std.testing.expectEqual(@as(u32, 1), spied.expiries);
    try std.testing.expect(spied.closing_after_expiry);
    if (spied.running_at_expiry) try std.testing.expect(spied.cancel_after_expiry);
    try std.testing.expectEqual(@as(u32, 1), spied.calls);
    try std.testing.expect(spied.closing);
    try std.testing.expect(!spied.failed);
    if (spied.canceled) {
        try std.testing.expect(spied.running_at_expiry);
        try std.testing.expectEqual(@as(usize, 0), spied.wrote);
    }
}

/// Checks that the log is the request, the sends the fake heard of, the
/// write deadline's expiry and one free, nothing after the expiry but that
/// free; `expectSendClosed`; and that the client, reading to the end, gets
/// exactly the bytes the fake heard of as sent and what that send's
/// completion says it wrote, unreported.
fn expectExpiredWhileSending(s: *Single, cl: c.fd_t, got: usize) !void {
    var total = got;
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = c.read(cl, &buf, buf.len);
        if (r < 0) return error.ClientRead;
        if (r == 0) break;
        total += @intCast(r);
    }
    const sends = s.count(.sent);
    if (s.n != sends + 4 or sends == 0) {
        s.dump();
        return error.UnexpectedEvents;
    }
    try std.testing.expectEqual(Kind.open, s.log[0].kind);
    try std.testing.expectEqual(Kind.recv, s.log[1].kind);
    try std.testing.expectEqual(@as(u8, 'R'), s.log[1].byte);
    for (s.log[2 .. 2 + sends]) |e| try std.testing.expectEqual(Kind.sent, e.kind);
    const x = s.log[2 + sends];
    try std.testing.expectEqual(Kind.expired, x.kind);
    try std.testing.expectEqual(@as(u32, 1), x.n);
    try std.testing.expectEqual(write_code, x.byte);
    try std.testing.expectEqual(Kind.free, s.log[3 + sends].kind);
    for (s.log[0..s.n]) |e| try std.testing.expectEqual(s.log[0].conn, e.conn);
    try expectSendClosed();
    try std.testing.expectEqual(reportedSent(s) + spied.wrote, total);
}

test "a write deadline the loop runs before a ready send's completion closes, and what that send wrote is not reported" {
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    var p = try partialSend(&s);
    defer _ = c.close(p.cl);
    const conn = s.lp.head.?;
    const sends = s.count(.sent);
    // The parked send can make progress and the write deadline is due
    // before the loop polls again. In that poll zio checks the timers, then
    // the backend completes the send with what it wrote, then the queued
    // callbacks run, the timer's first (zio 53ed3c377317, `Loop.poll`): the
    // expiry closes and asks to cancel the send, too late, and the send's
    // completion, with its natural result, only leads to the close.
    try spyOnSend(conn);
    try drainUntilWritable(p.cl, conn.fd, &p.got);
    dueNow(&s);
    try s.stepUntil(.free, 1);
    try std.testing.expectEqual(sends, s.count(.sent));
    try expectExpiredWhileSending(&s, p.cl, p.got);
    // The send had completed in the backend before the timer's callback.
    try std.testing.expect(!spied.running_at_expiry and !spied.canceled);
    try std.testing.expect(spied.wrote > 0);
    s.lp.stop.notify();
    try s.finish();
}

test "a partial send's completion the loop runs before a due write deadline is reported, keeps the arm, and that arm's expiry closes" {
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    var p = try partialSend(&s);
    defer _ = c.close(p.cl);
    const conn = s.lp.head.?;
    // The parked send can make progress; the write deadline becomes due
    // inside its completion's report, after the poll's timer check. The
    // completion is reported, partial, and the next send parks under the
    // same arm with the injected due time; the expiry comes at the next
    // poll's timer check, as that arm's, and closes.
    const from = s.n;
    try drainUntilWritable(p.cl, conn.fd, &p.got);
    due_on_sent = conn;
    try s.stepUntil(.sent, s.count(.sent) + 1);
    try std.testing.expect(due_on_sent == null);
    const e = try sentFrom(&s, from);
    try std.testing.expect(e.n < e.asked);
    try std.testing.expect(e.left > 0);
    try std.testing.expectEqual(@as(usize, 0), s.count(.expired));
    try std.testing.expect(conn.arm.? == p.arm);
    try std.testing.expect(!p.arm.retired);
    try std.testing.expectEqual(due_injected.?, p.arm.timer.deadline);
    try std.testing.expect(p.due.value != p.arm.timer.deadline.value);
    // The partial completion took the room the client's reads freed, and
    // the client reads no more: the next send parked (`spyOnSend` checks)
    // and stays in the kernel until the expiry.
    try spyOnSend(conn);
    try std.testing.expect(!writableNow(conn.fd));
    const sends = s.count(.sent);
    try s.stepUntil(.free, 1);
    try std.testing.expectEqual(sends, s.count(.sent));
    try expectExpiredWhileSending(&s, p.cl, p.got);
    // The expiry asked to cancel that send; its one completion carried
    // error.Canceled, unreported.
    try std.testing.expect(spied.running_at_expiry and spied.canceled);
    s.lp.stop.notify();
    try s.finish();
}

/// Whether the kernel reports `fd` writable now (a nonblocking snapshot).
fn writableNow(fd: c.fd_t) bool {
    var fds = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.OUT, .revents = 0 }};
    const r = c.poll(&fds, 1, 0);
    if (r < 0) @panic("poll for writability failed");
    return r == 1;
}

test "a write deadline that ends while its send waits in the kernel cancels that send, which completes canceled to the closing connection" {
    // On loopback TCP a send need not stay in the kernel: loopback may keep
    // freeing room in the server's send buffer after a send parks, so the
    // TCP test of an expiry beside a parked send ("a response whose write
    // deadline ends before any next byte arrives ...") allows either
    // outcome. A Unix-domain stream socket
    // gains room only when its peer reads (XNU and Linux move the bytes
    // into the peer's receive buffer at the send and free the sender's
    // room only at the peer's read, or its close), and this client never
    // reads, so the parked send stays in the kernel until the expiry. The
    // pair is the listener's accepted end and its client, not a
    // socketpair(2): serve.zig takes connections only from its accept.
    // Checked by runs on macOS (kqueue) and on Linux (epoll; items emb2ob
    // and ogcdwm, ./linux-check.sh).
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    respond_on_open = response_len;
    const cl = try s.listener.connect();
    // Closed before `s.deinit` runs (defers run last first): should a check
    // below fail with the send still parked, the close ends it.
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    // The fake starts the response at the open. Its sends complete at once
    // until the socket is full; serve.zig tries each itself, and hands the
    // one whose syscall returns EAGAIN to zio, which waits for writability
    // (`startSend`), on every backend. serve.zig starts the readiness poll
    // only beside a send so parked (`sendParked`). The poll in flight is the
    // event that this send waits in the kernel.
    try stepUntilPolling(&s);
    const conn = s.lp.head.?;
    try spyOnSend(conn);
    try std.testing.expect(!writableNow(conn.fd));
    dueNow(&s);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .expired, .n = 0, .byte = write_code },
        .{ .kind = .free },
    });
    try expectSendClosed();
    // The send was still in the kernel at the expiry, which asked to cancel
    // it; its one completion carried error.Canceled.
    try std.testing.expect(spied.running_at_expiry);
    try std.testing.expect(spied.cancel_after_expiry);
    try std.testing.expect(spied.canceled);
    s.lp.stop.notify();
    try s.finish();
}

/// The retired-arm test: a timer of the test's own, due before the
/// connection's, whose callback takes the connection's arm off while that
/// arm's own callback is already on its way.
var retire_conn: ?*serve.Conn = null;
var retired_seen: u32 = 0;
var cleared_inline: bool = false;

fn retireCb(_: *ev.Loop, _: *ev.Completion) void {
    const conn = retire_conn.?;
    const arm = conn.arm.?;
    // The connection's timer fired in the same batch: its result is set.
    cleared_inline = !arm.timer.c.has_result;
    conn.disarm();
    retired_seen = conn.retired_arms;
}

test "a timer whose callback is already on its way when its arm is replaced is retired: its callback reports nothing" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    open_dl = head_code;
    const cl = try s.listener.connect();
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    retire_conn = s.lp.head.?;
    retired_seen = 0;
    dueNow(&s);
    // Due at the start of the monotonic clock: before the connection's
    // deadline in the timer heap, so both fire in one batch, this first.
    var first = ev.Timer.init(.none);
    first.c.callback = retireCb;
    s.lp.loop.setTimer(&first, .{ .deadline = .zero });
    try s.lp.loop.poll(.zero);
    try std.testing.expect(!cleared_inline);
    try std.testing.expectEqual(@as(u32, 1), retired_seen);
    // The retired callback ran in the same batch and released the arm.
    try std.testing.expectEqual(@as(u32, 0), retire_conn.?.retired_arms);
    try std.testing.expect(retire_conn.?.arm == null);
    // The connection goes on without a deadline: the client's close ends it.
    _ = c.close(cl);
    try s.stepUntil(.free, 1);
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .recv, .n = 0, .byte = 0 }, .{ .kind = .free } });
    s.lp.stop.notify();
    try s.finish();
}

// ---- taking a backlog of connections in one accept callback (item sakmfp) ----
//
// The clients connect over a Unix-domain stream socket: its connect(2)
// returns once the kernel has queued the connection on the listener, so
// when the test polls the loop, every client it connected is pending
// (a TCP client's connect returns when its own side of the handshake is
// done, not when the server's kernel has queued it). The loop runs on the
// test's thread, so no callback is dispatched before that poll.

/// Connects every client in `clients` to `s`'s listener.
fn connectAll(s: *const Single, clients: []c.fd_t) !void {
    for (clients) |*cl| cl.* = try s.listener.connect();
}

fn closeAll(clients: []const c.fd_t) void {
    for (clients) |cl| _ = c.close(cl);
}

/// The open connections of the loop.
fn openConns(s: *const Single) u32 {
    var n: u32 = 0;
    var it = s.lp.head;
    while (it) |conn| : (it = conn.next) n += 1;
    return n;
}

test "connections pending when the accept's callback runs are all opened in that callback, within the batch" {
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    var clients: [5]c.fd_t = undefined;
    try connectAll(&s, &clients);
    defer closeAll(&clients);
    // The poll that dispatches the accept opens all five: the one its
    // completion returned and four taken directly, until EAGAIN. Before
    // item sakmfp it opened one and the next accept's completion waited for
    // the loop's next turn.
    try s.stepUntil(.open, 1);
    try std.testing.expectEqual(@as(usize, 5), s.count(.open));
    // EAGAIN ended the batch with slots free: the accept is armed again,
    // holding one slot beside the five connections'.
    try std.testing.expect(s.lp.armed);
    try std.testing.expect(!s.lp.paused);
    try std.testing.expectEqual(@as(u32, 6), serve.slots_used.load(.monotonic));
    // And it takes a client that comes later.
    const late = try s.listener.connect();
    defer _ = c.close(late);
    try s.stepUntil(.open, 6);
    s.lp.stop.notify();
    try s.stepUntil(.free, 6);
    try s.finish();
}

test "a backlog larger than the batch is opened over several turns, and an established connection is served meanwhile" {
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    serve.max_conns = 16;
    serve.accept_batch = 3;
    const est = try s.listener.connect();
    defer _ = c.close(est);
    try s.stepUntil(.open, 1);
    const est_conn = s.log[0].conn;
    const est_fd = s.lp.head.?.fd;
    // The established connection's byte is readable before the loop's next
    // poll. Its receive has not consumed it: on kqueue and epoll zio tried
    // it at `loop.add` (EAGAIN) and parked it; on io_uring it is an SQE
    // the kernel first sees at the next poll, so the test polls no more
    // before this wait (a receive in the kernel could take the byte first,
    // and the wait would never end).
    try send(est, "x");
    awaitReadable(est_fd);
    var clients: [7]c.fd_t = undefined;
    try connectAll(&s, &clients);
    defer closeAll(&clients);
    // Each poll opens at most the batch: the callback stops after three and
    // re-adds its accept, whose completion runs on a later turn (zio's
    // `processCompletions`, cited at `serve.accept_batch`). The seven take
    // at least three accept callbacks, so three turns, while the byte's
    // receive is ready at the first: it is reported before the last open
    // because the batch is bounded.
    var opened: usize = 1;
    var step: usize = 0;
    while (opened < 8) : (step += 1) {
        if (step == max_steps) {
            s.dump();
            return error.EventNeverCame;
        }
        try s.lp.loop.poll(.zero);
        s.collect();
        const now = s.count(.open);
        if (now - opened > serve.accept_batch) {
            s.dump();
            return error.BatchExceeded;
        }
        // The first poll takes a full batch: the backlog is pending.
        if (opened == 1 and now > 1) try std.testing.expectEqual(@as(usize, 4), now);
        opened = now;
    }
    // The established connection's byte was reported before the backlog's
    // last connection was opened.
    var recv_at: ?usize = null;
    var last_open: usize = 0;
    for (s.log[0..s.n], 0..) |e, i| switch (e.kind) {
        .recv => if (e.conn == est_conn and e.n == 1 and recv_at == null) {
            recv_at = i;
        },
        .open => last_open = i,
        else => {},
    };
    if (recv_at == null or recv_at.? > last_open) {
        s.dump();
        return error.EstablishedNotServed;
    }
    try std.testing.expectEqual(@as(u32, 8), openConns(&s));
    s.lp.stop.notify();
    try s.stepUntil(.free, 8);
    try s.finish();
}

test "when the slots run out the callback stops, admission pauses, and a released slot resumes it" {
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    serve.max_conns = 3;
    var clients: [5]c.fd_t = undefined;
    try connectAll(&s, &clients);
    defer closeAll(&clients);
    // Three slots: the armed accept's connection and two taken directly;
    // no slot is left to re-arm, so the acceptor pauses with two clients
    // still in the listen queue.
    try s.stepUntil(.open, 1);
    try std.testing.expectEqual(@as(usize, 3), s.count(.open));
    try std.testing.expect(!s.lp.armed);
    try std.testing.expect(s.lp.paused);
    try std.testing.expectEqual(@as(u32, 3), serve.slots_used.load(.monotonic));
    // The first client hangs up: its close releases a slot, the acceptor
    // re-arms with it and opens one more, then finds no slot again.
    _ = c.close(clients[0]);
    clients[0] = -1;
    try s.stepUntil(.free, 1);
    try s.stepUntil(.open, 4);
    try s.lp.loop.poll(.zero);
    s.collect();
    try std.testing.expectEqual(@as(usize, 4), s.count(.open));
    try std.testing.expect(!s.lp.armed);
    try std.testing.expect(s.lp.paused);
    try std.testing.expectEqual(@as(u32, 3), serve.slots_used.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 3), openConns(&s));
    s.lp.stop.notify();
    try s.stepUntil(.free, 4);
    try s.finish();
}

test "a direct accept that fails releases its slot, and the callback goes on with the next connection" {
    var s: Single = undefined;
    try s.initOn(64, .unix);
    defer s.deinit();
    // Every connection the callback takes itself is closed and reported as
    // ConnectionAborted, an error of the one pending connection.
    serve.testing.fail_accept_every = 1;
    var clients: [3]c.fd_t = undefined;
    try connectAll(&s, &clients);
    defer closeAll(&clients);
    try s.stepUntil(.open, 1);
    try s.lp.loop.poll(.zero);
    s.collect();
    // Only the completion's connection opened; both failed accepts gave
    // their slots back, and the accept is armed again.
    try std.testing.expectEqual(@as(usize, 1), s.count(.open));
    try std.testing.expect(s.lp.armed);
    try std.testing.expectEqual(@as(u32, 2), serve.slots_used.load(.monotonic));
    // The two failed connections were taken from the queue and closed:
    // their clients read the end of input at once (a client still queued,
    // or served, would find nothing to read: -1, EAGAIN).
    for (clients[1..]) |cl| {
        var b: [1]u8 = undefined;
        try std.testing.expectEqual(@as(isize, 0), c.recv(cl, &b, 1, c.MSG.DONTWAIT));
    }
    s.lp.stop.notify();
    try s.stepUntil(.free, 1);
    try s.finish();
}

// ---- admission across loops, each on its own thread ----

const nloops = 2;

const Multi = struct {
    lps: [nloops]serve.LoopCtx = undefined,
    /// Each loop's snapshot handle: notified by the test, answered by the
    /// loop with a `snapshot` event of its admission state.
    snaps: [nloops]ev.Async = undefined,
    threads: [nloops]std.Thread = undefined,
};

var multi: *Multi = undefined;

fn snapCb(_: *ev.Loop, comp: *ev.Completion) void {
    const a: *ev.Async = @fieldParentPtr("c", comp);
    a.getResult() catch {
        // Canceled by the loop's shutdown: the handle ends here.
        comp.flags.rearm = false;
        return;
    };
    const lp: *serve.LoopCtx = @ptrCast(@alignCast(comp.userdata.?));
    var conns: u32 = 0;
    var it = lp.head;
    while (it) |conn| : (it = conn.next) conns += 1;
    emit(.{ .kind = .snapshot, .loop = loop_index, .armed = lp.armed, .paused = lp.paused, .n = conns, .slots = serve.slots_used.load(.acquire) });
}

/// The shutdown in the multi-loop test: serve.zig's, then the end of the
/// loop's snapshot handle, so that the loop can finish.
fn stopMulti(loop: *ev.Loop, comp: *ev.Completion) void {
    serve.LoopCtx.stopCb(loop, comp);
    loop.cancel(&multi.snaps[loop_index].c);
}

fn loopThread(i: u8) void {
    loop_index = i;
    const lp = &multi.lps[i];
    if (!serve.startLoop(lp)) @panic("a loop failed to start");
    lp.stop.c.callback = stopMulti;
    const snap = &multi.snaps[i];
    snap.* = ev.Async.init();
    snap.c.callback = snapCb;
    snap.c.userdata = lp;
    snap.c.flags.rearm = true;
    lp.loop.add(&snap.c);
    emit(.{ .kind = .ready, .loop = i });
    lp.loop.run() catch @panic("a loop failed");
    if (lp.head != null) @panic("a loop ended with connections open");
    lp.loop.deinit();
    emit(.{ .kind = .done, .loop = i });
}

/// The next event, which must be of `kind`. It blocks until a loop writes
/// one: every awaited event is one the test's previous step made due.
fn expectEvent(kind: Kind) !Event {
    const e = readEvent();
    if (e.kind != kind) {
        std.debug.print("expected a {s} event, got", .{@tagName(kind)});
        printEvent(e);
        std.debug.print("\n", .{});
        return error.UnexpectedEvent;
    }
    return e;
}

/// Each loop's admission state, acknowledged by that loop after every event
/// the test has seen; checks that every slot is held by a connection or an
/// armed accept, and that some acceptor is armed while a slot is free.
fn snapshots() ![nloops]Event {
    for (&multi.snaps) |*a| a.notify();
    var got: [nloops]?Event = @splat(null);
    for (0..nloops) |_| {
        const e = try expectEvent(.snapshot);
        if (got[e.loop] != null) return error.TwoSnapshotsFromOneLoop;
        got[e.loop] = e;
    }
    var out: [nloops]Event = undefined;
    var held: u32 = 0;
    var any_armed = false;
    for (got, 0..) |g, i| {
        out[i] = g.?;
        try std.testing.expect(!(out[i].armed and out[i].paused));
        held += out[i].n + @intFromBool(out[i].armed);
        any_armed = any_armed or out[i].armed;
    }
    for (out) |e| {
        try std.testing.expectEqual(out[0].slots, e.slots);
    }
    try std.testing.expectEqual(held, out[0].slots);
    try std.testing.expect(out[0].slots <= serve.max_conns);
    if (out[0].slots < serve.max_conns) try std.testing.expect(any_armed);
    return out;
}

fn expectLoop(e: Event, armed: bool, paused: bool, conns: u32) !void {
    try std.testing.expectEqual(armed, e.armed);
    try std.testing.expectEqual(paused, e.paused);
    try std.testing.expectEqual(conns, e.n);
}

/// What the closing loop acknowledged after a hang-up: its snapshot, and the
/// connection it opened before taking it, if any.
const Settled = struct { snap: Event, opened: ?Event };

/// Closes a client, waits for its connection's end of input and free, then
/// for loop `lp_i`'s acknowledgement that the close has finished. The `free`
/// event comes from inside serve.zig's closeCb, before the close releases
/// its slot and re-arms the acceptor; the loop answers the snapshot request
/// only after that callback has returned, so the other loop's snapshots that
/// follow see the close's admission complete. A connection the re-armed
/// acceptor opens may come before that answer.
fn hangUp(client: c.fd_t, conn: u32, lp_i: u8) !Settled {
    _ = c.close(client);
    const r = try expectEvent(.recv);
    try std.testing.expectEqual(conn, r.conn);
    try std.testing.expectEqual(@as(u32, 0), r.n);
    const f = try expectEvent(.free);
    try std.testing.expectEqual(conn, f.conn);
    multi.snaps[lp_i].notify();
    var opened: ?Event = null;
    for (0..2) |_| {
        const e = readEvent();
        try std.testing.expectEqual(lp_i, e.loop);
        switch (e.kind) {
            .snapshot => return .{ .snap = e, .opened = opened },
            .open => {
                if (opened != null) return error.TwoOpens;
                opened = e;
            },
            else => {
                printEvent(e);
                return error.UnexpectedEvent;
            },
        }
    }
    return error.NoSnapshot;
}

test "admission across two loops: a full server pauses both acceptors, and the loop whose connection closes resumes" {
    // The loop threads run until their stop: a failure ends the process
    // with them rather than leave them running into the next test.
    // What failed is printed above (std.testing's message or the event).
    errdefer @panic("the multi-loop admission test failed");
    try std.testing.expectEqual(@as(u32, 0), serve.slots_used.load(.monotonic));
    try openEvents();
    defer closeEvents();
    room = 64;
    serve.max_conns = 2;
    open_dl = none_code;
    recv_dl = none_code;
    var listener = try Listener.open();
    defer listener.close();
    var m: Multi = .{};
    multi = &m;
    for (&m.lps) |*lp| lp.* = .{ .lfd = listener.fd };
    for (&m.threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, loopThread, .{@as(u8, @intCast(i))});
    for (0..nloops) |_| _ = try expectEvent(.ready);

    // Both acceptors armed: they hold both slots.
    var s = try snapshots();
    for (s) |e| try expectLoop(e, true, false, 0);

    // The first client goes to either loop, X; X finds no slot to re-arm.
    const c1 = try listener.connect();
    const o1 = try expectEvent(.open);
    const x = o1.loop;
    const y = 1 - x;
    s = try snapshots();
    try expectLoop(s[x], false, true, 1);
    try expectLoop(s[y], true, false, 0);

    // The second can only go to Y, which then pauses too.
    const c2 = try listener.connect();
    const o2 = try expectEvent(.open);
    try std.testing.expectEqual(y, o2.loop);
    s = try snapshots();
    try expectLoop(s[x], false, true, 1);
    try expectLoop(s[y], false, true, 1);

    // The third waits in the listen queue: the snapshots, taken after its
    // connect returned, show no acceptor armed to take it.
    const c3 = try listener.connect();
    s = try snapshots();
    try expectLoop(s[x], false, true, 1);
    try expectLoop(s[y], false, true, 1);

    // X's connection closes: its slot goes to X's acceptor, which takes the
    // third client while Y stays paused. If X had not re-armed, its
    // acknowledgement would show it unarmed with nothing opened, and the
    // test fails here instead of waiting for an open that never comes.
    const h1 = try hangUp(c1, o1.conn, x);
    const o3 = h1.opened orelse blk: {
        try std.testing.expect(h1.snap.armed);
        break :blk try expectEvent(.open);
    };
    try std.testing.expectEqual(x, o3.loop);
    s = try snapshots();
    try expectLoop(s[x], false, true, 1);
    try expectLoop(s[y], false, true, 1);

    // Y's connection closes: Y re-arms; nothing waits for it.
    try std.testing.expectEqual(@as(?Event, null), (try hangUp(c2, o2.conn, y)).opened);
    s = try snapshots();
    try expectLoop(s[x], false, true, 1);
    try expectLoop(s[y], true, false, 0);

    // The last one closes: both acceptors armed again.
    try std.testing.expectEqual(@as(?Event, null), (try hangUp(c3, o3.conn, x)).opened);
    s = try snapshots();
    for (s) |e| try expectLoop(e, true, false, 0);

    // The shutdown. No connection is open and no client acts, so nothing but
    // the stop notification can wake a loop.
    for (&m.lps) |*lp| lp.stop.notify();
    for (0..nloops) |_| _ = try expectEvent(.done);
    for (m.threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), serve.slots_used.load(.monotonic));
}

/// Where a client's connection was opened: its conn and loop, learned from
/// the byte it sent ('a' + its index), which the loop reported.
const Placed = struct { conn: u32, loop: u8 };

test "a backlog pending when two loops start is taken by the two up to the slots, and a released slot takes one more" {
    // Item sakmfp: each accept callback takes pending connections itself
    // while slots are free. The seven clients connect (over a Unix-domain
    // socket, queued when connect returns) and each sends its byte before
    // either loop starts, so both loops find the backlog at their first
    // turn. Five slots: five open, how many on each loop is not assumed
    // (one loop may take all five before the other starts), and both
    // acceptors pause with two clients still queued.
    errdefer @panic("the multi-loop backlog test failed");
    try std.testing.expectEqual(@as(u32, 0), serve.slots_used.load(.monotonic));
    try openEvents();
    defer closeEvents();
    room = 64;
    serve.max_conns = 5;
    serve.accept_batch = serve.default_accept_batch;
    serve.testing = .{};
    open_dl = none_code;
    recv_dl = none_code;
    var listener = try Listener.openUnix();
    defer listener.close();
    var clients: [7]c.fd_t = undefined;
    for (&clients, 0..) |*cl, i| {
        cl.* = try listener.connect();
        try send(cl.*, &.{@as(u8, @intCast('a' + i))});
    }
    defer for (clients) |cl| {
        _ = c.close(cl);
    };
    var m: Multi = .{};
    multi = &m;
    for (&m.lps) |*lp| lp.* = .{ .lfd = listener.fd };
    for (&m.threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, loopThread, .{@as(u8, @intCast(i))});

    // Two ready, five opens and the five bytes, in any order across loops.
    var placed: [7]?Placed = @splat(null);
    var readies: usize = 0;
    var opens: usize = 0;
    var bytes: usize = 0;
    while (readies + opens + bytes < 2 + 5 + 5) {
        const e = readEvent();
        switch (e.kind) {
            .ready => readies += 1,
            .open => opens += 1,
            .recv => {
                const i = e.byte -% 'a';
                if (e.n != 1 or i >= clients.len or placed[i] != null) return error.UnexpectedEvent;
                placed[i] = .{ .conn = e.conn, .loop = e.loop };
                bytes += 1;
            },
            else => {
                printEvent(e);
                return error.UnexpectedEvent;
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 5), opens);
    var s = try snapshots();
    try expectLoop(s[0], false, true, s[0].n);
    try expectLoop(s[1], false, true, s[1].n);
    try std.testing.expectEqual(@as(u32, 5), s[0].n + s[1].n);

    // An opened client hangs up: its loop X re-arms with the released slot
    // and opens one of the two queued, whose byte it then reports; then it
    // pauses again.
    const k = for (placed, 0..) |p, i| {
        if (p != null) break i;
    } else unreachable;
    const x = placed[k].?.loop;
    _ = c.close(clients[k]);
    clients[k] = -1;
    var freed = false;
    var opened = false;
    var reported = false;
    while (!(freed and opened and reported)) {
        const e = readEvent();
        if (e.loop != x) {
            printEvent(e);
            return error.UnexpectedEvent;
        }
        switch (e.kind) {
            .recv => if (e.n == 0) {
                try std.testing.expectEqual(placed[k].?.conn, e.conn);
            } else {
                const i = e.byte -% 'a';
                if (i >= clients.len or placed[i] != null) return error.UnexpectedEvent;
                placed[i] = .{ .conn = e.conn, .loop = e.loop };
                reported = true;
            },
            .free => {
                try std.testing.expectEqual(placed[k].?.conn, e.conn);
                freed = true;
            },
            .open => {
                if (opened) return error.TwoOpens;
                opened = true;
            },
            else => {
                printEvent(e);
                return error.UnexpectedEvent;
            },
        }
    }
    s = try snapshots();
    try expectLoop(s[0], false, true, s[0].n);
    try expectLoop(s[1], false, true, s[1].n);
    try std.testing.expectEqual(@as(u32, 5), s[0].n + s[1].n);

    // The shutdown: every open connection's receive is canceled and it
    // closes; the client still queued is never accepted.
    for (&m.lps) |*lp| lp.stop.notify();
    var dones: usize = 0;
    var frees: usize = 0;
    while (dones < nloops) {
        const e = readEvent();
        switch (e.kind) {
            .done => dones += 1,
            .free => frees += 1,
            .refused => {},
            else => {
                printEvent(e);
                return error.UnexpectedEvent;
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 5), frees);
    for (m.threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), serve.slots_used.load(.monotonic));
}

// ---- the stop notification against the loop's end (zio issue 927) ----

/// The stop handle while a notify that moved it to notified is still waking
/// its loop: the pinned zio's `Async.Pending` with `busy` held.
const notifier_waking: ev.Async.Pending = .{ .notified = true, .busy = true, .disarmed = false };

test "the loop does not take its stop while the stop's notifier is still waking it" {
    // https://github.com/lalinsky/zio/issues/927: under zio 9bef33d a notify
    // could let the loop take the stop, end, and close its poller in deinit
    // before the notify's own wake syscall, which then panicked (kqueue:
    // EBADF). The pinned zio holds the handle's completion until its notifier
    // is done with the loop (`busy`, https://github.com/lalinsky/zio/pull/928).
    // `notify` has no point a test can pause it at, so this test performs its
    // steps here, as zio's own test does (src/ev/test/async_stress.zig, "Async:
    // not completed while its notifier is still waking the loop"), on serve's
    // stop handle and its real shutdown: the notify stops before its wake
    // syscall, another event wakes the loop, and serve's shutdown must wait
    // for the notify to finish.
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);

    // The notify's steps up to its wake syscall: it moves the armed handle to
    // notified, holding `busy`, and requests the loop's wake. The loop runs on
    // this thread and is not asleep, so the request alone wakes it and
    // `wakeAsync` makes no syscall; the notify is now as if inside it.
    if (s.lp.stop.pending.cmpxchgStrong(.{ .disarmed = false }, notifier_waking, .acq_rel, .monotonic)) |old| {
        std.debug.print("the stop handle was not armed and idle: {}\n", .{old});
        return error.StopNotArmed;
    }
    // On a failure below, the loop's deinit (in `s.deinit`) would wait for
    // this notify to clear `busy`, which only this thread does: clear it
    // first (a second clear after the one below changes nothing).
    defer _ = s.lp.stop.pending.fetchAnd(ev.Async.Pending.clear_busy, .release);
    s.lp.loop.wakeAsync();

    // A byte wakes the loop. The poll that delivers it, and the one after it,
    // each look at the stop handle (the wake request is pending), find the
    // notifier busy, and leave the stop for later: serve's shutdown has not
    // run and the connection is still open.
    try send(cl, "x");
    awaitReadable(s.lp.head.?.fd);
    try s.stepUntil(.recv, 1);
    try s.lp.loop.poll(.zero);
    try std.testing.expectEqual(@as(u32, 0), stops);
    try std.testing.expect(!s.lp.stopping);
    try std.testing.expect(s.lp.head != null);
    try std.testing.expectEqual(notifier_waking, s.lp.stop.pending.load(.acquire));

    // The notify returns from its wake syscall; the loop then takes the stop,
    // shuts down, and ends.
    _ = s.lp.stop.pending.fetchAnd(ev.Async.Pending.clear_busy, .release);
    try s.stepUntil(.free, 1);
    try s.finish();
    try std.testing.expectEqual(ev.Async.Pending{ .disarmed = true }, s.lp.stop.pending.load(.acquire));
}

// ---- orderings of a completion, its cancel and an expiry, delivered explicitly ----
//
// The tests above let the loop choose the order in which a poll delivers
// completions and timers, and that order depends on the backend (two of them
// state io_uring's separately). The tests below fix it themselves (item
// qgrnr3): the loop still performs every operation and completes it, but the
// completion's callback is replaced (`hold`) by one that only notes it, and
// the test then hands each held completion to serve.zig's own callback
// (`forward`) in the order the test names. zio allows this: "The completion
// is already dead when it runs, and for a completion with neither `rearm`
// nor a group or queue owner the loop does not touch it after the callback
// returns" (53ed3c377317, src/ev/completion.zig, `Completion.callback`, as
// cited at serve.zig's `Op`), and no completion held here has either. So
// serve.zig sees the same calls, with the results the kernel gave, as when a
// backend completes them in that order. The tests assert what serve.zig
// reports to Lean in each order (each event at most once, a stale
// generation's expiry not at all, a current one's always) and that work
// still runnable is kept; they do not assert which order a backend takes.

/// One completion held back from serve.zig: `callback` is serve.zig's own,
/// and `completed` says the loop has completed it and called `heldCb`
/// instead. `keep`: the completion is added again under the same callback
/// field (the loop's `wake`), so it stays held after each `forward`.
const Hold = struct {
    comp: *ev.Completion = undefined,
    callback: *const ev.Completion.CallbackFn = undefined,
    installed: bool = false,
    completed: bool = false,
    keep: bool = false,
};
var holds: [4]Hold = @splat(.{});

fn heldCb(_: *ev.Loop, comp: *ev.Completion) void {
    for (&holds) |*h| {
        if (!h.installed or h.comp != comp) continue;
        if (h.completed) @panic("a held completion completed twice before it was forwarded");
        h.completed = true;
        return;
    }
    @panic("heldCb called for a completion no hold holds");
}

/// Holds back the completion `comp`, in flight or to be added, from its callback.
fn hold(comp: *ev.Completion, keep: bool) *Hold {
    for (&holds) |*h| {
        if (h.installed) continue;
        h.* = .{ .comp = comp, .callback = comp.callback.?, .installed = true, .keep = keep };
        comp.callback = heldCb;
        return h;
    }
    @panic("no free hold");
}

/// Hands the held, completed `h` to serve.zig's callback, as the loop would
/// have. A hold without `keep` ends, with its completion's callback field
/// back as the loop leaves it, before the callback runs: serve.zig may free
/// or reuse that memory, so the hold does not touch it afterwards.
fn forward(s: *Single, h: *Hold) !void {
    if (!h.installed or !h.completed) return error.NotCompleted;
    h.completed = false;
    if (!h.keep) {
        h.installed = false;
        h.comp.callback = h.callback;
    }
    h.callback(&s.lp.loop, h.comp);
}

/// Ends every hold the test left, before `Single.deinit`: each completion
/// still in flight gets serve.zig's callback back, and each completed one is
/// forwarded, so a test that returned early leaves nothing undelivered.
fn releaseHolds(s: *Single) void {
    for (&holds) |*h| {
        if (h.installed) h.comp.callback = h.callback;
    }
    for (&holds) |*h| {
        if (h.installed and h.completed) forward(s, h) catch unreachable;
        h.* = .{};
    }
}

/// Polls the loop until the loop has completed every hold in `hs`, at most
/// `max_steps` polls, taking the events into the log.
fn stepUntilHeld(s: *Single, hs: []const *Hold) !void {
    var step: usize = 0;
    while (true) : (step += 1) {
        s.collect();
        for (hs) |h| {
            if (!h.completed) break;
        } else return;
        if (step == max_steps) {
            s.dump();
            return error.NeverCompleted;
        }
        try s.lp.loop.poll(.zero);
    }
}

/// The result of the held receive `h`.
fn heldRecv(h: *const Hold) ev.NetRecv.Error!usize {
    const r: *ev.NetRecv = @fieldParentPtr("c", h.comp);
    return r.getResult();
}

/// Holds the receive in flight and the current deadline's timer of the one
/// connection, after its client sent `bytes` (none: "") and that deadline
/// was made due; returns once the loop has completed the timer, and the
/// receive too when `bytes` is not empty.
fn holdRecvAndExpiry(s: *Single, cl: c.fd_t, bytes: []const u8) !struct { recv: *Hold, timer: *Hold } {
    const conn = s.lp.head.?;
    const op = conn.cur orelse return error.NoOperation;
    if (op.kind != .recv) return error.NotReceiving;
    const r = hold(&op.comp.recv.c, false);
    const t = hold(&conn.arm.?.timer.c, false);
    if (bytes.len > 0) {
        try send(cl, bytes);
        awaitReadable(conn.fd);
    }
    dueNow(s);
    if (bytes.len > 0) try stepUntilHeld(s, &.{ r, t }) else try stepUntilHeld(s, &.{t});
    return .{ .recv = r, .timer = t };
}

test "explicit order: an expiry before its receive's completion closes, and the bytes received are not reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    open_dl = head_code;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const h = try holdRecvAndExpiry(&s, cl, "a");
    try std.testing.expectEqual(@as(usize, 1), try heldRecv(h.recv));
    // The expiry closes and cancels the receive, which has completed
    // already: the cancel changes nothing, and the completion, with its
    // byte, only leads to the close.
    try forward(&s, h.timer);
    try std.testing.expect(s.lp.head.?.closing);
    try forward(&s, h.recv);
    try s.stepUntil(.free, 1);
    s.lp.stop.notify();
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .expired, .n = 0, .byte = head_code }, .{ .kind = .free } });
}

test "explicit order: an expiry that cancels its receive in flight closes, and the canceled completion is not reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    open_dl = head_code;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const h = try holdRecvAndExpiry(&s, cl, "");
    try std.testing.expect(!h.recv.completed);
    // The expiry runs while the receive waits in the kernel: its cancel
    // reaches it, and its completion comes after, canceled.
    try forward(&s, h.timer);
    try stepUntilHeld(&s, &.{h.recv});
    try std.testing.expectError(error.Canceled, heldRecv(h.recv));
    try forward(&s, h.recv);
    try s.stepUntil(.free, 1);
    s.lp.stop.notify();
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .expired, .n = 0, .byte = head_code }, .{ .kind = .free } });
}

test "explicit order: a receive before the expiry of the generation it ends is reported, and that expiry is stale" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    open_dl = head_code;
    recv_dl = idle_code;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const conn = s.lp.head.?;
    const old = conn.arm.?;
    const h = try holdRecvAndExpiry(&s, cl, "a");
    // The receive starts generation 1 under the idle deadline. Generation
    // 0's timer has fired, so it cannot be taken off: it is retired.
    try forward(&s, h.recv);
    try s.stepUntil(.recv, 1);
    try std.testing.expect(conn.arm.? != old);
    try std.testing.expect(old.retired);
    try std.testing.expectEqual(@as(u32, 1), conn.retired_arms);
    // Its callback only releases it (`old` is freed): nothing is reported,
    // and the connection goes on receiving.
    try forward(&s, h.timer);
    try std.testing.expectEqual(@as(u32, 0), conn.retired_arms);
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .recv, .n = 1, .byte = 'a' } });
    try std.testing.expect(conn.cur.?.kind == .recv);
    // The current generation's expiry is reported and closes.
    dueNow(&s);
    try s.stepUntil(.free, 1);
    s.lp.stop.notify();
    try s.finish();
    s.collect();
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'a' },
        .{ .kind = .expired, .n = 1, .byte = idle_code },
        .{ .kind = .free },
    });
}

test "explicit order: a receive within the period before that period's expiry is reported, and the expiry is current and closes" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    open_dl = head_code;
    recv_keeps = true;
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const conn = s.lp.head.?;
    const arm = conn.arm.?;
    const h = try holdRecvAndExpiry(&s, cl, "a");
    // The receive keeps the period: the arm whose timer fired stays the
    // current one, and its expiry, delivered after, is that period's.
    try forward(&s, h.recv);
    try s.stepUntil(.recv, 1);
    try std.testing.expect(conn.arm.? == arm);
    try std.testing.expect(!arm.retired);
    try forward(&s, h.timer);
    try s.stepUntil(.free, 1);
    s.lp.stop.notify();
    try s.finish();
    s.collect();
    try expectLog(&s, &.{
        .{ .kind = .open },
        .{ .kind = .recv, .n = 1, .byte = 'a' },
        .{ .kind = .expired, .n = 0, .byte = head_code },
        .{ .kind = .free },
    });
}

test "explicit order: a receive completed before the shutdown's cancel is reported once, with its bytes, and the next is refused" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const conn = s.lp.head.?;
    const r = hold(&conn.cur.?.comp.recv.c, false);
    try send(cl, "a");
    awaitReadable(conn.fd);
    try stepUntilHeld(&s, &.{r});
    // The stop finds the receive completed: its cancel changes nothing.
    s.lp.stop.notify();
    var step: usize = 0;
    while (stops == 0) : (step += 1) {
        if (step == max_steps) return error.StopNeverRan;
        try s.lp.loop.poll(.zero);
    }
    try std.testing.expectEqual(@as(usize, 1), stop_nphases);
    try std.testing.expect(stop_phases[0] != .running);
    try forward(&s, r);
    try s.stepUntil(.free, 1);
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .recv, .n = 1, .byte = 'a' }, .{ .kind = .refused }, .{ .kind = .free } });
}

test "explicit order: a receive the shutdown's cancel reaches completes canceled and is refused" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const r = hold(&s.lp.head.?.cur.?.comp.recv.c, false);
    s.lp.stop.notify();
    try stepUntilHeld(&s, &.{r});
    try std.testing.expectEqual(@as(u32, 1), stops);
    try std.testing.expectEqual(ev.Completion.State.Phase.running, stop_phases[0]);
    try std.testing.expectError(error.Canceled, heldRecv(r));
    try forward(&s, r);
    try s.stepUntil(.free, 1);
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .refused }, .{ .kind = .free } });
}

/// Opens one connection that starts a response of `len` bytes, sent
/// `testing.chunk` bytes at a time, and holds the loop's `wake` (the turn
/// that reports a send the loop performed) and the write deadline's timer;
/// returns once the loop has completed both, the deadline made due, with
/// the first send's result waiting in the ready list.
fn holdWroteAndExpiry(s: *Single, len: usize) !struct { cl: c.fd_t, wake: *Hold, timer: *Hold } {
    respond_on_open = len;
    report_sent = true;
    const w = hold(&s.lp.wake.c, true);
    const cl = try s.listener.connect();
    errdefer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const conn = s.lp.head.?;
    try std.testing.expect(conn.cur.?.kind == .wrote);
    try std.testing.expect(s.lp.ready_head == conn);
    const t = hold(&conn.arm.?.timer.c, false);
    dueNow(s);
    try stepUntilHeld(s, &.{ w, t });
    try std.testing.expect(s.lp.ready_head == conn);
    return .{ .cl = cl, .wake = w, .timer = t };
}

test "explicit order: an expiry before its queued performed send closes, and the send is not reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    const h = try holdWroteAndExpiry(&s, 16);
    defer _ = c.close(h.cl);
    const conn = s.lp.head.?;
    try forward(&s, h.timer);
    try std.testing.expect(conn.closing);
    // The send has completed: nothing to cancel, and it stays in the ready
    // list, whose turn delivers it to the close.
    try std.testing.expect(s.lp.ready_head == conn);
    try forward(&s, h.wake);
    try std.testing.expect(s.lp.ready_head == null);
    try s.stepUntil(.free, 1);
    s.lp.stop.notify();
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .expired, .n = 0, .byte = write_code }, .{ .kind = .free } });
}

test "explicit order: a queued performed send that ends the response before its expiry is reported, and that expiry is stale" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    const h = try holdWroteAndExpiry(&s, 16);
    defer _ = c.close(h.cl);
    const conn = s.lp.head.?;
    const arm = conn.arm.?;
    // The whole response went in one send: the connection receives under no
    // deadline, and the write deadline's fired timer is retired.
    try forward(&s, h.wake);
    s.collect();
    try std.testing.expect(conn.cur.?.kind == .recv);
    try std.testing.expect(conn.arm == null);
    try std.testing.expect(arm.retired);
    try std.testing.expectEqual(@as(u32, 1), conn.retired_arms);
    try forward(&s, h.timer);
    try std.testing.expectEqual(@as(u32, 0), conn.retired_arms);
    s.lp.stop.notify();
    try s.stepUntil(.free, 1);
    try std.testing.expectEqual(@as(u32, 16), s.log[1].n);
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .sent }, .{ .kind = .written }, .{ .kind = .refused }, .{ .kind = .free } });
}

test "explicit order: a queued performed send within the response before its expiry is reported, and the expiry is current and closes" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    serve.testing.chunk = 8;
    const h = try holdWroteAndExpiry(&s, 16);
    defer _ = c.close(h.cl);
    const conn = s.lp.head.?;
    const arm = conn.arm.?;
    // Half the response went: the next send runs under the same write
    // deadline (the arm whose timer fired stays current) and is performed
    // at once, its result queued for the next turn.
    try forward(&s, h.wake);
    try std.testing.expect(conn.arm.? == arm);
    try std.testing.expect(!arm.retired);
    try std.testing.expect(conn.cur.?.kind == .wrote);
    try std.testing.expect(s.lp.ready_head == conn);
    try forward(&s, h.timer);
    try std.testing.expect(conn.closing);
    try stepUntilHeld(&s, &.{h.wake});
    try forward(&s, h.wake);
    try s.stepUntil(.free, 1);
    try std.testing.expectEqual(@as(u32, 8), s.log[1].n);
    try std.testing.expectEqual(@as(u32, 8), s.log[1].left);
    s.lp.stop.notify();
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .sent }, .{ .kind = .expired, .n = 0, .byte = write_code }, .{ .kind = .free } });
}

test "explicit order: a performed send queued in the ready list when the shutdown runs is reported once, and the connection closes once" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    respond_on_open = 16;
    report_sent = true;
    const w = hold(&s.lp.wake.c, true);
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const conn = s.lp.head.?;
    try std.testing.expect(conn.cur.?.kind == .wrote);
    // The turn that would report the send is due, and held.
    try stepUntilHeld(&s, &.{w});
    try std.testing.expect(s.lp.ready_head == conn);
    s.lp.stop.notify();
    var step: usize = 0;
    while (stops == 0) : (step += 1) {
        if (step == max_steps) return error.StopNeverRan;
        try s.lp.loop.poll(.zero);
    }
    // The shutdown leaves the performed send queued: the connection is not
    // closing, and the drain runs. No deadline and not the drain can end
    // here (`Single.init` sets their budgets to `never`), so the wake's
    // turn is the next thing that reaches the connection.
    try std.testing.expect(conn.cur.?.kind == .wrote);
    try std.testing.expect(s.lp.ready_head == conn);
    try std.testing.expect(!conn.closing);
    try std.testing.expect(s.lp.drain_armed);
    try std.testing.expect(!s.lp.drained);
    s.collect();
    try expectLog(&s, &.{.{ .kind = .open }});
    // Its turn reports it: the whole response went, Lean asks for the next
    // receive, which the shutdown declines, and the connection closes.
    try forward(&s, w);
    try std.testing.expect(s.lp.ready_head == null);
    try s.stepUntil(.free, 1);
    try std.testing.expectEqual(@as(u32, 16), s.log[1].n);
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .sent }, .{ .kind = .written }, .{ .kind = .refused }, .{ .kind = .free } });
}

test "explicit order: the drain's end before a queued performed send's turn closes, and the send is not reported" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    respond_on_open = 16;
    report_sent = true;
    const w = hold(&s.lp.wake.c, true);
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
    const conn = s.lp.head.?;
    try std.testing.expect(conn.cur.?.kind == .wrote);
    // The turn that would report the send is due, and held.
    try stepUntilHeld(&s, &.{w});
    try std.testing.expect(s.lp.ready_head == conn);
    s.lp.stop.notify();
    var step: usize = 0;
    while (stops == 0) : (step += 1) {
        if (step == max_steps) return error.StopNeverRan;
        try s.lp.loop.poll(.zero);
    }
    // The shutdown leaves the performed send queued, and the drain runs.
    try std.testing.expect(s.lp.drain_armed);
    try std.testing.expect(!conn.closing);
    // The drain is made due and its expiry held: the loop has completed
    // both the wake and the drain's timer, with the send still queued.
    const d = hold(&s.lp.drain.c, false);
    s.lp.loop.setTimer(&s.lp.drain, .{ .duration = .zero });
    try stepUntilHeld(&s, &.{ w, d });
    try std.testing.expect(conn.cur.?.kind == .wrote);
    try std.testing.expect(s.lp.ready_head == conn);
    s.collect();
    try expectLog(&s, &.{.{ .kind = .open }});
    // The drain's end comes first: `Conn.cut` closes the connection
    // (`expire`); the send has completed, so nothing is canceled, and it
    // stays in the ready list, whose turn delivers it to the close.
    try forward(&s, d);
    try std.testing.expect(s.lp.drained);
    try std.testing.expect(!s.lp.drain_armed);
    try std.testing.expect(conn.closing);
    try std.testing.expect(conn.cur.?.kind == .wrote);
    try std.testing.expect(s.lp.ready_head == conn);
    try forward(&s, w);
    try std.testing.expect(s.lp.ready_head == null);
    try s.stepUntil(.free, 1);
    try s.finish();
    s.collect();
    try expectLog(&s, &.{ .{ .kind = .open }, .{ .kind = .free } });
}

/// The fake's ids of the connections in the loop's ready list, in its order.
fn readyIds(s: *const Single, out: []u32) []u32 {
    var k: usize = 0;
    var it = s.lp.ready_head;
    while (it) |conn| : (it = conn.ready_next) {
        out[k] = connOf(conn.state).id;
        k += 1;
    }
    return out[0..k];
}

/// The `sent` events from log index `from` on, as the fake's connection ids.
fn sentIds(s: *const Single, from: usize, out: []u32) []u32 {
    var k: usize = 0;
    for (s.log[from..s.n]) |e| {
        if (e.kind != .sent) continue;
        out[k] = e.conn;
        k += 1;
    }
    return out[0..k];
}

test "explicit order: connections that perform their next send during a ready turn are reported once in it and kept for the next" {
    var s: Single = undefined;
    try s.init(64);
    defer s.deinit();
    defer releaseHolds(&s);
    // Three connections each send a response of three 8-byte sends.
    serve.testing.chunk = 8;
    respond_on_open = 24;
    report_sent = true;
    const w = hold(&s.lp.wake.c, true);
    var cls: [3]c.fd_t = undefined;
    for (&cls, 0..) |*cl, i| {
        cl.* = s.listener.connect() catch |err| {
            for (cls[0..i]) |o| _ = c.close(o);
            return err;
        };
    }
    defer for (cls) |cl| {
        _ = c.close(cl);
    };
    awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 3);
    try stepUntilHeld(&s, &.{w});
    var ids: [3]u32 = undefined;
    var buf: [4]u32 = undefined;
    const first = readyIds(&s, &buf);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    @memcpy(&ids, first);
    // The list holds each opened connection once.
    for (s.log[0..3]) |e| {
        try std.testing.expectEqual(Kind.open, e.kind);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u32, &ids, &.{e.conn}));
    }

    // Turn 1: each connection's first send is reported once, in the list's
    // order; each performs its second at once, which joins a new list for
    // the next turn instead of being taken in this one, and the wake is
    // added again.
    var from = s.n;
    try forward(&s, w);
    s.collect();
    try std.testing.expectEqualSlices(u32, &ids, sentIds(&s, from, &buf));
    try std.testing.expectEqualSlices(u32, &ids, readyIds(&s, &buf));
    try std.testing.expect(s.lp.wake_armed);

    // Before turn 2, the middle connection's write deadline ends: it closes,
    // and its send, queued already, stays in the list for the turn, which
    // delivers it to the close, unreported. The others are reported and
    // kept for turn 3.
    const mid: *serve.Conn = s.lp.ready_head.?.ready_next.?;
    const t = hold(&mid.arm.?.timer.c, false);
    s.lp.loop.setTimer(&mid.arm.?.timer, .{ .duration = .zero });
    try stepUntilHeld(&s, &.{ w, t });
    try forward(&s, t);
    try std.testing.expect(mid.closing);
    try std.testing.expectEqualSlices(u32, &ids, readyIds(&s, &buf));
    from = s.n;
    try forward(&s, w);
    s.collect();
    const kept = [2]u32{ ids[0], ids[2] };
    try std.testing.expectEqualSlices(u32, &kept, sentIds(&s, from, &buf));
    try std.testing.expectEqualSlices(u32, &kept, readyIds(&s, &buf));

    // Turn 3: the last sends end both responses.
    try stepUntilHeld(&s, &.{w});
    from = s.n;
    try forward(&s, w);
    s.collect();
    try std.testing.expectEqualSlices(u32, &kept, sentIds(&s, from, &buf));
    try std.testing.expect(s.lp.ready_head == null);
    try std.testing.expect(!s.lp.wake_armed);
    s.lp.stop.notify();
    try s.stepUntil(.free, 3);
    try s.finish();
    s.collect();

    // Exactly once: each connection opened, was freed, and had each of its
    // sends reported once (the middle one only its first), the middle one's
    // expiry reported once, each response ended once.
    for (ids, 0..) |id, i| {
        var opens: usize = 0;
        var sents: usize = 0;
        var expiries: usize = 0;
        var writtens: usize = 0;
        var frees: usize = 0;
        var left: u32 = 24;
        for (s.log[0..s.n]) |e| {
            if (e.conn != id) continue;
            switch (e.kind) {
                .open => opens += 1,
                .sent => {
                    sents += 1;
                    try std.testing.expectEqual(@as(u32, 8), e.n);
                    left -= 8;
                    try std.testing.expectEqual(left, e.left);
                },
                .expired => {
                    expiries += 1;
                    try std.testing.expectEqual(@as(u32, 0), e.n);
                    try std.testing.expectEqual(write_code, e.byte);
                },
                .written => writtens += 1,
                .free => frees += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 1), opens);
        try std.testing.expectEqual(@as(usize, 1), frees);
        try std.testing.expectEqual(@as(usize, if (i == 1) 1 else 3), sents);
        try std.testing.expectEqual(@as(usize, if (i == 1) 1 else 0), expiries);
        try std.testing.expectEqual(@as(usize, if (i == 1) 0 else 1), writtens);
    }
}
