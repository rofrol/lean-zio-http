// Spike: one zio.ev loop per thread, all accepting on one listening socket.
// The loop keeps no protocol or buffering state: each connection holds a Lean
// state (lean/Conn.lean), reports the outcome of every operation to it through
// glue.c, and performs the action it answers (receive, send, close).
const std = @import("std");
const zio = @import("zio");
const ev = zio.ev;
const os = zio.os;
const net = os.net;

/// Conn.Action as decoded by glue.c.
const Action = extern struct {
    kind: u8, // 0 recv, 1 send, 2 close, 3 none
    room: usize, // recv: most bytes to receive
    len: usize, // send: bytes glue.c copied into out
};

const State = ?*anyopaque; // a Lean Conn.State, owned by the connection

extern fn ekk_open(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_recv(state: *State, data: [*]const u8, n: usize, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_sent(state: *State, n: usize, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_fail(state: *State, out: [*]u8, cap: usize, act: *Action) void;
extern fn ekk_free(state: State) void;
extern fn ekk_thread_init() void;
extern fn ekk_thread_fini() void;

const alloc = std.heap.c_allocator;

// One receive takes at most min(room, recv_cap) bytes; Lean buffers them.
const recv_cap = 8192;
// One send writes at most out_cap bytes; Lean asks again for the rest.
const out_cap = 8192;

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
};
var testing: Testing = .{};
var recv_count = std.atomic.Value(u32).init(0);
var send_count = std.atomic.Value(u32).init(0);
var conn_ids = std.atomic.Value(u64).init(0);

/// Whether the receive or send that just completed, counted in `count`, is to
/// be reported as failed.
fn injectFailure(count: *std.atomic.Value(u32)) bool {
    if (testing.fail_every == 0) return false;
    return (count.fetchAdd(1, .monotonic) + 1) % testing.fail_every == 0;
}

fn capChunk(n: usize) usize {
    return if (testing.chunk == 0) n else @min(n, testing.chunk);
}

const Comp = union { recv: ev.NetRecv, send: ev.NetSend, close: ev.NetClose };

/// One submitted operation: its completion, stamped with its number on the
/// connection. Untraced, every operation of a connection reuses the slot
/// embedded in it; traced, each gets its own allocation, never freed, so a
/// duplicate or stale completion arrives at an address and number that are
/// not the current operation's and fails the check in `finish`.
const Op = struct {
    comp: Comp = undefined,
    id: u64,
    conn: *Conn,
};

const Conn = struct {
    fd: ev.Backend.NetHandle,
    loop: *ev.Loop,
    state: State = null,
    slot: Op = undefined,
    cur: ?*Op = null,
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

    /// Numbers and returns the next operation; ends the process if one is outstanding.
    fn begin(self: *Conn) *Op {
        if (self.freed or self.started != self.done) @panic("operation submitted while another is in flight");
        self.started += 1;
        const op = if (testing.trace) alloc.create(Op) catch @panic("no memory for a traced operation") else &self.slot;
        op.* = .{ .id = self.started, .conn = self };
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

    /// Performs the action Lean answered.
    fn apply(self: *Conn, act: Action) void {
        switch (act.kind) {
            0 => {
                if (act.room == 0) return self.fail(); // excluded by Conn.step_recv
                self.startRecv(capChunk(@min(act.room, recv_cap)));
            },
            1 => {
                if (act.len == 0) return self.fail(); // excluded by Conn.step_send
                self.out_len = capChunk(act.len);
                self.startSend();
            },
            2 => self.close(),
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

    fn startRecv(self: *Conn, n: usize) void {
        const op = self.begin();
        self.recv_len = n;
        op.comp = .{ .recv = ev.NetRecv.init(self.fd, .fromSlice(self.in[0..n], &self.recv_iov), .{}) };
        op.comp.recv.c.callback = recvCb;
        op.comp.recv.c.userdata = op;
        self.loop.add(&op.comp.recv.c);
    }

    fn recvCb(_: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        self.finish(op, c, .recv);
        const n = op.comp.recv.getResult() catch return self.fail();
        if (n > self.recv_len) @panic("receive returned more bytes than asked");
        if (injectFailure(&recv_count)) {
            self.injected_recv += 1;
            return self.fail();
        }
        var act: Action = undefined;
        ekk_recv(&self.state, &self.in, n, &self.out, out_cap, &act);
        self.apply(act);
    }

    fn startSend(self: *Conn) void {
        const op = self.begin();
        op.comp = .{ .send = ev.NetSend.init(self.fd, .fromSlice(self.out[0..self.out_len], &self.send_iov), .{}) };
        op.comp.send.c.callback = sendCb;
        op.comp.send.c.userdata = op;
        self.loop.add(&op.comp.send.c);
    }

    fn sendCb(_: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        self.finish(op, c, .send);
        const n = op.comp.send.getResult() catch return self.fail();
        if (n > self.out_len) @panic("send reported more bytes than given");
        if (injectFailure(&send_count)) {
            self.injected_send += 1;
            return self.fail();
        }
        var act: Action = undefined;
        ekk_sent(&self.state, n, &self.out, out_cap, &act);
        self.apply(act);
    }

    fn close(self: *Conn) void {
        const op = self.begin();
        op.comp = .{ .close = ev.NetClose.init(self.fd) };
        op.comp.close.c.callback = closeCb;
        op.comp.close.c.userdata = op;
        self.loop.add(&op.comp.close.c);
    }

    fn closeCb(_: *ev.Loop, c: *ev.Completion) void {
        const op: *Op = @ptrCast(@alignCast(c.userdata.?));
        const self = op.conn;
        self.finish(op, c, .close);
        ekk_free(self.state);
        self.state = null;
        if (testing.trace) {
            std.debug.print("free {d} {d} {d} {d}\n", .{ self.id, self.done, self.injected_recv, self.injected_send });
            self.freed = true; // kept allocated, like its operations: a later completion panics in finish()
        } else alloc.destroy(self);
    }
};

const Acceptor = struct {
    loop: *ev.Loop,
    lfd: ev.Backend.NetHandle,
    comp: ev.NetAccept = undefined,

    fn start(self: *Acceptor) void {
        self.comp = ev.NetAccept.init(self.lfd, null, null);
        self.comp.c.callback = acceptCb;
        self.comp.c.userdata = self;
        self.loop.add(&self.comp.c);
    }

    fn acceptCb(loop: *ev.Loop, c: *ev.Completion) void {
        const self: *Acceptor = @ptrCast(@alignCast(c.userdata.?));
        if (self.comp.getResult()) |fd| {
            net.setNoDelay(fd, true) catch {};
            if (alloc.create(Conn)) |conn| {
                conn.* = .{ .fd = fd, .loop = loop, .id = conn_ids.fetchAdd(1, .monotonic) };
                if (testing.trace) std.debug.print("open {d}\n", .{conn.id});
                var act: Action = undefined;
                ekk_open(&conn.state, &conn.out, out_cap, &act);
                conn.apply(act);
            } else |_| net.close(fd);
        } else |_| {} // spike: every accept error is retried; production must classify them
        self.start();
    }
};

/// Writes a loop's one-byte startup report; a write that fails would leave the
/// waiter blocked forever, so it ends the process instead.
fn sendReport(report: std.c.fd_t, code: u8) void {
    if (std.c.write(report, &[1]u8{code}, 1) != 1) {
        std.debug.print("could not report a loop's startup\n", .{});
        std.process.exit(1);
    }
}

/// Sets up one loop with its acceptor, reports the outcome as one byte on
/// `report` (0 ready, 1 failed), then runs the loop; a failing loop ends the process.
fn runLoop(lfd: ev.Backend.NetHandle, lean_thread: bool, report: std.c.fd_t) void {
    if (lean_thread) ekk_thread_init();
    defer if (lean_thread) ekk_thread_fini();
    var loop: ev.Loop = undefined;
    loop.init(.{ .allocator = alloc }) catch {
        sendReport(report, 1);
        return;
    };
    defer loop.deinit();
    var acc: Acceptor = .{ .loop = &loop, .lfd = lfd };
    acc.start();
    sendReport(report, 0);
    loop.run() catch |err| {
        std.debug.print("loop failed: {}\n", .{err});
        std.process.exit(1);
    };
}

/// Prints "ready" once one success byte has arrived from each of `threads`
/// loops; a failure byte or a broken pipe ends the process.
fn awaitReady(fd: std.c.fd_t, threads: u32) void {
    var got: u32 = 0;
    while (got < threads) : (got += 1) {
        var b: [1]u8 = undefined;
        if (std.c.read(fd, &b, 1) != 1 or b[0] != 0) {
            std.debug.print("a loop failed to start\n", .{});
            std.process.exit(1);
        }
    }
    std.debug.print("ready\n", .{}); // bench.sh and check/ wait for this line
}

/// Serves on 127.0.0.1:port with `threads` loops (the calling thread runs the
/// last one) and prints "ready" once every loop has registered its acceptor.
/// `chunk`, `fail_every` and `trace` are the test settings (`Testing`), all
/// zero in normal runs. Returns 1 on setup failure; otherwise does not return.
export fn ekk_serve(port: u16, threads: u32, chunk: usize, fail_every: u32, trace: u8) callconv(.c) u8 {
    if (threads == 0) return 1;
    testing = .{ .chunk = chunk, .fail_every = fail_every, .trace = trace != 0 };
    const lfd = net.socket(.ipv4, .stream, .ip, .{ .nonblocking = true }) catch return 1;
    const one: c_int = 1;
    net.setsockopt(lfd, net.SOL.SOCKET, net.SO.REUSEADDR, std.mem.asBytes(&one)) catch return 1;
    var sa: net.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    net.bind(lfd, @ptrCast(&sa), @sizeOf(net.sockaddr.in)) catch return 1;
    net.listen(lfd, 4096) catch return 1;

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return 1;
    const waiter = std.Thread.spawn(.{}, awaitReady, .{ fds[0], threads }) catch return 1;
    waiter.detach();
    var i: u32 = 1;
    while (i < threads) : (i += 1) {
        const t = std.Thread.spawn(.{}, runLoop, .{ lfd, true, fds[1] }) catch return 1;
        t.detach();
    }
    runLoop(lfd, false, fds[1]);
    return 1;
}
