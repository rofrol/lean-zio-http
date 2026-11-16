// Spike: one zio.ev loop per thread, all accepting on one listening socket;
// the bytes buffered on a connection go to Lean through glue.c, which frames,
// parses and answers the request.
const std = @import("std");
const zio = @import("zio");
const ev = zio.ev;
const os = zio.os;
const net = os.net;

extern fn ekk_call(req: [*]const u8, n: usize, out: [*]u8, cap: usize) usize;
extern fn ekk_thread_init() void;
extern fn ekk_thread_fini() void;

const alloc = std.heap.c_allocator;

// Must hold the largest request Lean accepts: maxHeadBytes + CRLFCRLF + maxBodyBytes
// in lean/Main.lean (8192 + 4 + 8192). A buffer that fills while Lean still wants
// more bytes closes the connection.
const in_cap = 8192 + 4 + 8192;
// Lean's result: a 5-byte prefix (kind, consumed as u32 LE) and the response.
const out_cap = 8192;
const prefix_len = 5;

const Conn = struct {
    fd: ev.Backend.NetHandle,
    loop: *ev.Loop,
    comp: union { recv: ev.NetRecv, send: ev.NetSend, close: ev.NetClose } = undefined,
    in: [in_cap]u8 = undefined,
    in_len: usize = 0,
    out: [out_cap]u8 = undefined,
    out_len: usize = 0,
    out_off: usize = 0,
    close_after: bool = false,
    recv_iov: [1]os.iovec = undefined,
    send_iov: [1]os.iovec_const = undefined,

    fn startRecv(self: *Conn) void {
        self.comp = .{ .recv = ev.NetRecv.init(self.fd, .fromSlice(self.in[self.in_len..], &self.recv_iov), .{}) };
        self.comp.recv.c.callback = recvCb;
        self.comp.recv.c.userdata = self;
        self.loop.add(&self.comp.recv.c);
    }

    fn recvCb(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Conn = @ptrCast(@alignCast(c.userdata.?));
        const n = self.comp.recv.getResult() catch return self.close();
        if (n == 0) return self.close();
        self.in_len += n;
        self.process();
    }

    fn process(self: *Conn) void {
        // Lean frames, parses and answers; result = kind, consumed (u32 LE), response.
        const m = ekk_call(&self.in, self.in_len, &self.out, self.out.len);
        if (m == std.math.maxInt(usize) or m < prefix_len) return self.close();
        const kind = self.out[0];
        if (kind == 0) {
            if (self.in_len == self.in.len) return self.close();
            return self.startRecv();
        }
        const consumed: usize = std.mem.readInt(u32, self.out[1..prefix_len], .little);
        // A respond result must consume what it answered and carry a response.
        if (kind > 2 or consumed == 0 or consumed > self.in_len or m == prefix_len) return self.close();
        std.mem.copyForwards(u8, self.in[0 .. self.in_len - consumed], self.in[consumed..self.in_len]);
        self.in_len -= consumed;
        self.close_after = kind == 2;
        self.out_len = m;
        self.out_off = prefix_len;
        self.startSend();
    }

    fn startSend(self: *Conn) void {
        self.comp = .{ .send = ev.NetSend.init(self.fd, .fromSlice(self.out[self.out_off..self.out_len], &self.send_iov), .{}) };
        self.comp.send.c.callback = sendCb;
        self.comp.send.c.userdata = self;
        self.loop.add(&self.comp.send.c);
    }

    fn sendCb(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Conn = @ptrCast(@alignCast(c.userdata.?));
        const n = self.comp.send.getResult() catch return self.close();
        if (n == 0) return self.close(); // no progress on a nonempty send
        self.out_off += n;
        if (self.out_off < self.out_len) return self.startSend();
        if (self.close_after) return self.close();
        if (self.in_len > 0) return self.process();
        self.startRecv();
    }

    fn close(self: *Conn) void {
        self.comp = .{ .close = ev.NetClose.init(self.fd) };
        self.comp.close.c.callback = closeCb;
        self.comp.close.c.userdata = self;
        self.loop.add(&self.comp.close.c);
    }

    fn closeCb(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Conn = @ptrCast(@alignCast(c.userdata.?));
        alloc.destroy(self);
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
                conn.* = .{ .fd = fd, .loop = loop };
                conn.startRecv();
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
/// Returns 1 on setup failure; otherwise does not return.
export fn ekk_serve(port: u16, threads: u32) callconv(.c) u8 {
    if (threads == 0) return 1;
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
