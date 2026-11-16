// The transport: one zio.ev loop per thread, all accepting on one listening
// socket. The loop keeps no protocol or buffering state: each connection holds
// a Lean state (Server/Conn.lean), reports the outcome of every operation
// to it through glue.c, and performs the action it answers (receive, send,
// close, or a query, which the loop's PostgreSQL pool in pg.zig runs and whose
// result it reports back). Around that the loop owns admission (at most `max_conns`
// connections, the rest wait in the kernel's listen queue), the
// classification of accept errors, and the graceful shutdown on SIGTERM or
// SIGINT (README, "Production contract").
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
};

pub const State = ?*anyopaque; // a Lean Conn.State, owned by the connection

extern fn ekk_open(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_recv(state: *State, data: [*]const u8, n: usize, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_sent(state: *State, n: usize, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_fail(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_refused(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_answer(state: *State, result: ?*anyopaque, out: [*]u8, cap: usize, act: *Action) void;
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

/// Test settings, set by ekk_serve before any loop starts and read-only after.
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
var testing: Testing = .{};
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

const Comp = union { recv: ev.NetRecv, send: ev.NetSend, close: ev.NetClose };
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

const Conn = struct {
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

    /// Performs the action Lean answered; during shutdown a receive is
    /// declined and reported as `refused` instead.
    fn apply(self: *Conn, act: Action) void {
        switch (act.kind) {
            0 => {
                if (act.room == 0) return self.fail(); // excluded by Conn.step_recv
                if (self.lp.stopping) return self.refuse();
                self.startRecv(capChunk(@min(act.room, recv_cap)));
            },
            1 => {
                if (act.len == 0) return self.fail(); // excluded by Conn.step_send
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
            // `none` answers only events after close, and none are reported then (Conn.step_close).
            else => @panic("Lean answered none for a live connection"),
        }
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

    fn recvCb(_: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        self.finish(op, c, .recv);
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

    fn sendCb(_: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        self.finish(op, c, .send);
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

    fn close(self: *Conn) void {
        const op = self.begin(.close);
        op.comp = .{ .close = ev.NetClose.init(self.fd) };
        op.comp.close.c.callback = closeCb;
        op.comp.close.c.userdata = op;
        self.lp.loop.add(&op.comp.close.c);
    }

    fn closeCb(_: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        self.finish(op, c, .close);
        ekk_free(self.state);
        self.state = null;
        const lp = self.lp;
        lp.unlink(self);
        releaseSlot();
        if (testing.trace) {
            std.debug.print("free {d} {d} {d} {d}\n", .{ self.id, self.done, self.injected_recv, self.injected_send });
            self.freed = true; // kept allocated, like its operations: a later completion panics in finish()
        } else alloc.destroy(self);
        lp.resumeAccept();
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

    fn acceptCb(_: *ev.Loop, c: *ev.Completion) void {
        const self: *LoopCtx = @ptrCast(@alignCast(c.userdata.?));
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
                // The listening socket itself is broken. Also, unresolved: Linux's
                // other pending-connection errnos (accept(2): ENETUNREACH,
                // EHOSTUNREACH, EHOSTDOWN, ENONET, ENOPROTOOPT, EOPNOTSUPP) reach
                // here, because the pinned zio maps them to Unexpected or
                // OperationNotSupported together with errors of a broken socket
                // (src/os/net.zig, errnoToAcceptError); the owner decides (README,
                // "Production contract").
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
        net.setNoDelay(fd, true) catch {};
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
    /// `loop.run` returns once nothing of this loop is in flight.
    pub fn stopCb(_: *ev.Loop, c: *ev.Completion) void {
        const self: *LoopCtx = @ptrCast(@alignCast(c.userdata.?));
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
        // The shutdown test checks that a send was in flight when the stop came.
        if (testing.trace) std.debug.print("stop {d} {d}\n", .{ receives, sends });
    }
};

var loops: []LoopCtx = &.{};
/// The PostgreSQL connection string and the connections per loop (0: none).
var pg_conninfo: [*:0]const u8 = "";
var pg_conns: u32 = 0;

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
    lp.pool.init(&lp.loop, pg_conninfo, slots, testing.trace);
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
    for (loops) |*lp| lp.stop.notify();
}

/// Serves on 127.0.0.1:port with `threads` loops (the calling thread runs the
/// last one) and at most `maxc` connections; prints "ready" once every loop
/// has registered its acceptor. On SIGTERM or SIGINT every loop shuts down
/// gracefully; once all have, it prints "stopped" and returns 0. Each loop
/// has at most `conns` PostgreSQL connections to `conninfo` (a Lean String,
/// kept for the process's life). The rest are the test settings (`Testing`),
/// all zero in normal runs. Returns 1 on setup failure.
export fn ekk_serve(port: u16, threads: u32, maxc: u32, conninfo: *anyopaque, conns: u32, chunk: usize, fail_every: u32, trace: u8, crash_recv: u32, crash_send: u32) callconv(.c) u8 {
    if (threads == 0 or maxc == 0) return 1;
    pg_conninfo = ekk_string_cstr(conninfo);
    pg_conns = conns;
    testing = .{ .chunk = chunk, .fail_every = fail_every, .trace = trace != 0, .crash_after_recv = crash_recv, .crash_after_send = crash_send };
    max_conns = maxc;
    // Each database connection holds libpq's socket and the loop's duplicate.
    if (ekk_fd_room(@as(c_ulong, maxc) + fd_reserve + 2 * @as(c_ulong, threads) * (1 + @as(c_ulong, conns))) != 0) {
        std.debug.print("RLIMIT_NOFILE cannot hold --max-conns {d} connections\n", .{maxc});
        return 1;
    }
    const stop_fd = ekk_stop_signals();
    if (stop_fd < 0) return 1;
    const lfd = net.socket(.ipv4, .stream, .ip, .{ .nonblocking = true }) catch return 1;
    const one: c_int = 1;
    net.setsockopt(lfd, net.SOL.SOCKET, net.SO.REUSEADDR, std.mem.asBytes(&one)) catch return 1;
    var sa: net.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    net.bind(lfd, @ptrCast(&sa), @sizeOf(net.sockaddr.in)) catch return 1;
    net.listen(lfd, 4096) catch return 1;

    loops = alloc.alloc(LoopCtx, threads) catch return 1;
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
