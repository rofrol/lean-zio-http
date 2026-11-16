//! Controlled-interleaving tests of the zio contracts that serve.zig's graceful
//! shutdown and admission rely on (`zig build test`; README, "Production
//! contract"). serve.zig runs on real zio.ev loops and real sockets. glue.c
//! (the Lean side) is replaced by the fake below, which always gives the same
//! answers: after an open, and after a receive that returned bytes, it asks
//! to receive again; at end of input, on a refusal and on a failure it asks
//! to close. Clients connect over TCP on 127.0.0.1. Before a single-loop test
//! polls its loop for an event, it waits (`awaitReadable`) until the kernel
//! has made that event ready: a connection queued on the listening socket, or
//! bytes readable at the server's end. The loop's nonblocking polls then find
//! it at once.
//!
//! Each call into the fake is an event: a fixed-size record written to a pipe
//! in one write, which is atomic up to PIPE_BUF. A test whose loops run on
//! other threads therefore reads every loop's events in the order each loop
//! made them.
const std = @import("std");
const zio = @import("zio");
const ev = zio.ev;
const serve = @import("serve.zig");

const c = std.c;
extern "c" fn socket(domain: c_uint, kind: c_uint, protocol: c_uint) c_int;
extern "c" fn getsockname(fd: c.fd_t, addr: *c.sockaddr, len: *c.socklen_t) c_int;

/// The most nonblocking polls a single-loop test makes while it waits for an
/// event that its last step has already made ready: running out means the
/// expected callback never ran.
const max_steps = 1000;

// ---- the fake glue.c ----

const Kind = enum(u8) { open, recv, refused, fail, free, ready, snapshot, done };

const Event = extern struct {
    kind: Kind,
    /// The loop whose thread made the event (multi-loop test).
    loop: u8 = 0,
    /// snapshot: the loop's acceptor is armed, or paused.
    armed: bool = false,
    paused: bool = false,
    conn: u32 = 0,
    /// recv: bytes received (0: end of input); snapshot: open connections.
    n: u32 = 0,
    /// snapshot: `slots_used`, as the loop read it.
    slots: u32 = 0,
    /// recv: the first byte received.
    byte: u8 = 0,
};

/// The Lean state of one fake connection.
const FakeConn = struct { id: u32, loop: u8 };

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
    act.* = .{ .kind = kind, .room = n, .len = 0, .query = null };
}

export fn ekk_open(state: *serve.State, _: [*]u8, _: usize, act: *serve.Action) void {
    enter("ekk_open");
    const fc = std.heap.c_allocator.create(FakeConn) catch @panic("out of memory");
    fc.* = .{ .id = next_conn.fetchAdd(1, .monotonic), .loop = loop_index };
    state.* = fc;
    emit(.{ .kind = .open, .loop = fc.loop, .conn = fc.id });
    answer(act, 0, room);
}

export fn ekk_recv(state: *serve.State, data: [*]const u8, n: usize, _: [*]u8, _: usize, act: *serve.Action) void {
    enter("ekk_recv");
    const fc = connOf(state.*);
    emit(.{ .kind = .recv, .loop = fc.loop, .conn = fc.id, .n = @intCast(n), .byte = if (n > 0) data[0] else 0 });
    if (n == 0) answer(act, 2, 0) else answer(act, 0, room);
}

export fn ekk_refused(state: *serve.State, _: [*]u8, _: usize, act: *serve.Action) void {
    enter("ekk_refused");
    const fc = connOf(state.*);
    emit(.{ .kind = .refused, .loop = fc.loop, .conn = fc.id });
    answer(act, 2, 0);
}

export fn ekk_fail(state: *serve.State, _: [*]u8, _: usize, act: *serve.Action) void {
    enter("ekk_fail");
    const fc = connOf(state.*);
    emit(.{ .kind = .fail, .loop = fc.loop, .conn = fc.id });
    answer(act, 2, 0);
}

export fn ekk_free(state: serve.State) void {
    enter("ekk_free");
    const fc = connOf(state);
    emit(.{ .kind = .free, .loop = fc.loop, .conn = fc.id });
    std.heap.c_allocator.destroy(fc);
}

// The fake never asks to send or to query, and these tests never call ekk_serve.
export fn ekk_sent(_: *serve.State, _: usize, _: [*]u8, _: usize, _: *serve.Action) void {
    @panic("ekk_sent: the fake never asks to send");
}
export fn ekk_answer(_: *serve.State, _: ?*anyopaque, _: [*]u8, _: usize, _: *serve.Action) void {
    @panic("ekk_answer: the fake never asks to query");
}
export fn ekk_string_cstr(_: *anyopaque) [*:0]const u8 {
    @panic("ekk_string_cstr: only ekk_serve calls it");
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
export fn ekk_pg_lost(_: ?*anyopaque) ?*anyopaque {
    @panic("ekk_pg_lost");
}
export fn ekk_pg_start(_: [*:0]const u8) ?*anyopaque {
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
    addr: c.sockaddr.in,

    /// A nonblocking listening socket on 127.0.0.1 at a port the kernel picks.
    fn open() !Listener {
        const fd = socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        var sa = std.mem.zeroes(c.sockaddr.in);
        sa.family = c.AF.INET;
        sa.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
        if (c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0) return error.Bind;
        if (c.listen(fd, 16) != 0) return error.Listen;
        var len: c.socklen_t = @sizeOf(c.sockaddr.in);
        if (getsockname(fd, @ptrCast(&sa), &len) != 0) return error.Getsockname;
        const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
        if (c.fcntl(fd, c.F.SETFL, nonblock) != 0) return error.Fcntl;
        return .{ .fd = fd, .addr = sa };
    }

    fn close(self: *Listener) void {
        _ = c.close(self.fd);
    }

    /// A blocking client connected to the listener.
    fn connect(self: *const Listener) !c.fd_t {
        const fd = socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        if (c.connect(fd, @ptrCast(&self.addr), @sizeOf(c.sockaddr.in)) != 0) return error.Connect;
        return fd;
    }
};

/// Waits until the kernel reports `fd` readable: a connection queued on a
/// listening socket, or bytes (or an end of input) on a connection.
fn awaitReadable(fd: c.fd_t) void {
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

const Single = struct {
    lp: serve.LoopCtx,
    listener: Listener,
    log: [64]Event = undefined,
    n: usize = 0,

    fn init(self: *Single, recv_room: usize) !void {
        try std.testing.expectEqual(@as(u32, 0), serve.slots_used.load(.monotonic));
        try openEvents();
        room = recv_room;
        stops = 0;
        serve.max_conns = 8;
        self.listener = try Listener.open();
        self.n = 0;
        self.lp = .{ .lfd = self.listener.fd };
        if (!serve.startLoop(&self.lp)) return error.StartLoop;
        self.lp.stop.c.callback = stopWrapped;
    }

    fn deinit(self: *Single) void {
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

    /// Polls the loop without blocking until `want` events of `kind` have
    /// arrived in all, at most `max_steps` polls.
    fn stepUntil(self: *Single, kind: Kind, want: usize) !void {
        var step: usize = 0;
        while (true) : (step += 1) {
            while (pendingEvent()) |e| {
                if (self.n == self.log.len) @panic("the event log is full");
                self.log[self.n] = e;
                self.n += 1;
            }
            if (self.count(kind) >= want) return;
            if (step == max_steps) {
                std.debug.print("waited for {d} {s} events\n", .{ want, @tagName(kind) });
                self.dump();
                return error.EventNeverCame;
            }
            try self.lp.loop.poll(.zero);
        }
    }

    /// Runs the loop to its end: after the shutdown it has nothing left in flight.
    fn finish(self: *Single) !void {
        try self.lp.loop.run();
        try std.testing.expect(self.lp.head == null);
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
    // stop is notified, before the loop polls again. In that one poll the parked receive returns "a" and the stop
    // completes, in that order. The callback for "a" starts the next
    // receive, which finds "b" at once, so its completion is queued with
    // its result before stopCb runs. The cancel then finds it completed,
    // which `stop_phases` shows.
    try send(cl, "ab");
    awaitReadable(s.lp.head.?.fd);
    s.lp.stop.notify();
    try s.stepUntil(.free, 1);
    try s.finish();
    try std.testing.expectEqual(@as(usize, 1), stop_nphases);
    try std.testing.expectEqual(ev.Completion.State.Phase.completed, stop_phases[0]);
    // "b" arrives as received (not error.Canceled); the receive asked after it
    // is declined (refused) because the shutdown has begun.
    const want = [_]struct { kind: Kind, byte: u8 = 0 }{
        .{ .kind = .open },
        .{ .kind = .recv, .byte = 'a' },
        .{ .kind = .recv, .byte = 'b' },
        .{ .kind = .refused },
        .{ .kind = .free },
    };
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
