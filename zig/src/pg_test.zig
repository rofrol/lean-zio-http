//! Deterministic tests of pg.zig's pool (`zig build test`; README,
//! "PostgreSQL"): a real zio.ev loop and real sockets, with pg.c replaced by
//! the scripted fake below. This test is linked without pg.c, so its
//! `export fn ekk_*` are the symbols pg.zig's `extern fn`s resolve to; they
//! keep pg.c's C signatures, with `?*anyopaque` for the opaque session and
//! Lean values. These tests check pg.zig against the contract pg.c documents
//! (each function's comment there), not that libpq keeps it; pg_glue_test.c
//! runs pg.c against libpq.
//!
//! A slot's libpq socket is one end of a socketpair; the test holds the other
//! end ("the peer") and makes the slot's duplicate readable (a byte from the
//! peer) and unwritable (the slot's send buffer filled) or writable (the peer
//! drained) at the step it chooses. The fake's `flush` result is scripted and
//! need not match the socket's buffer: these tests drive the pool's
//! transitions, not libpq's buffering.
//!
//! The loop is stepped with nonblocking polls until the state the step's
//! readiness must produce is observed, at most `max_steps` polls: running out
//! means the expected callback never ran, and the test fails with the fake's
//! call log.
//!
//! They run on macOS (kqueue) and on Linux (epoll, `./linux-check.sh`); the
//! last Linux run is recorded in serve_test.zig's header.
const std = @import("std");
const zio = @import("zio");
const ev = zio.ev;
const pg = @import("pg.zig");

const c = std.c;
extern "c" fn socketpair(domain: c_uint, kind: c_uint, protocol: c_uint, sv: *[2]c.fd_t) c_int;
extern "c" fn close(fd: c.fd_t) c_int;

const Lean = ?*anyopaque;
const max_steps = 1000;

// ---- the fake pg.c ----

/// A Lean value as the fake makes it: a query, rows, or an error.
const Obj = struct {
    kind: enum { query, rows, err, abandoned },
    sqlstate: [5]u8 = "     ".*,
    /// query: Query.timeoutMs.
    timeout_ms: ?u32 = null,
};

const Session = struct {
    id: u32,
    /// "libpq's socket": the slot end of the test's socketpair.
    fd: c.fd_t,
    /// The last collect returned 2 and the query is not yet answered.
    closing: bool = false,
};

const Kind = enum { start, connect_poll, finish, send, flush, consume, collect, deliver };
const Event = struct { kind: Kind, session: u32 = 0 };

/// Return values of one fake function, in order. When they run out, the
/// function returns `repeat`, or the test panics: an unexpected call.
const Script = struct {
    vals: [16]c_int = undefined,
    len: usize = 0,
    pos: usize = 0,
    repeat: ?c_int = null,

    fn push(self: *Script, vs: []const c_int) void {
        for (vs) |v| {
            self.vals[self.len] = v;
            self.len += 1;
        }
    }

    fn next(self: *Script, comptime name: []const u8) c_int {
        if (self.pos < self.len) {
            self.pos += 1;
            return self.vals[self.pos - 1];
        }
        if (self.repeat) |v| return v;
        fake.dump();
        @panic("unexpected call of " ++ name);
    }

    fn done(self: *const Script) bool {
        return self.pos == self.len;
    }
};

const Fake = struct {
    log: [256]Event = undefined,
    /// Calls logged; past the log's capacity only counted.
    calls: usize = 0,
    count: std.EnumArray(Kind, usize) = .initFill(0),
    /// 1: `start` makes a session; 0: it fails (NULL).
    start: Script = .{},
    connect_poll: Script = .{},
    send: Script = .{},
    flush: Script = .{},
    consume: Script = .{},
    /// 0 more input, 1 rows, -1 the session ends with 0A000 (COPY), 2 the
    /// query's error 0A000 is kept while collect's own output (the Close of
    /// a forgotten statement) is flushed; a 1 or -1 after it answers that
    /// error.
    collect: Script = .{},
    /// The socket the next session's `ekk_pg_socket` returns.
    next_fd: c.fd_t = -1,
    sessions: u32 = 0,
    /// Lean values alive: made by the fake, not yet dropped or delivered.
    live: i64 = 0,
    /// Duplicates the pool took and the session each belongs to.
    dups: [16]struct { fd: c.fd_t, session: u32 } = undefined,
    ndups: usize = 0,

    fn note(self: *Fake, kind: Kind, session: u32) void {
        if (self.calls < self.log.len) self.log[self.calls] = .{ .kind = kind, .session = session };
        self.calls += 1;
        self.count.getPtr(kind).* += 1;
    }

    /// The kinds logged from call `from` on.
    fn since(self: *const Fake, from: usize) []const Event {
        return self.log[from..@min(self.calls, self.log.len)];
    }

    fn dump(self: *const Fake) void {
        std.debug.print("fake call log ({d} calls):", .{self.calls});
        for (self.since(0)) |e| std.debug.print(" {s}/{d}", .{ @tagName(e.kind), e.session });
        std.debug.print("\n", .{});
    }

    fn scriptsDone(self: *const Fake) bool {
        return self.start.done() and self.connect_poll.done() and self.send.done() and
            self.flush.done() and self.consume.done() and self.collect.done();
    }
};

var fake: Fake = .{};

fn newObj(o: Obj) Lean {
    const p = std.testing.allocator.create(Obj) catch @panic("out of memory");
    p.* = o;
    fake.live += 1;
    return p;
}

fn freeObj(v: Lean) Obj {
    const p: *Obj = @ptrCast(@alignCast(v orelse @panic("a NULL Lean value dropped or delivered")));
    const o = p.*;
    std.testing.allocator.destroy(p);
    fake.live -= 1;
    return o;
}

fn sessionOf(p: ?*anyopaque) *Session {
    return @ptrCast(@alignCast(p.?));
}

export fn ekk_pg_error(sqlstate: [*:0]const u8, _: [*:0]const u8) Lean {
    var o: Obj = .{ .kind = .err };
    @memcpy(&o.sqlstate, sqlstate[0..5]);
    return newObj(o);
}

export fn ekk_pg_abandoned(sqlstate: [*:0]const u8, _: [*:0]const u8) Lean {
    var o: Obj = .{ .kind = .abandoned };
    @memcpy(&o.sqlstate, sqlstate[0..5]);
    return newObj(o);
}

export fn ekk_pg_lost(_: ?*anyopaque) Lean {
    return newObj(.{ .kind = .err, .sqlstate = "08006".* });
}

export fn ekk_pg_lost_sent(_: ?*anyopaque) Lean {
    return newObj(.{ .kind = .abandoned, .sqlstate = "08006".* });
}

/// pg.c's contract: none gives `dflt`, 1 to `ceiling` itself, else 0.
export fn ekk_query_timeout_ms(q: Lean, dflt: c_uint, ceiling: c_uint) c_uint {
    const p: *Obj = @ptrCast(@alignCast(q.?));
    const ms = p.timeout_ms orelse return dflt;
    return if (ms >= 1 and ms <= ceiling) ms else 0;
}

/// The startup options the fake's last session was started with.
var started_options: ?[*:0]const u8 = null;

export fn ekk_pg_start(_: [*:0]const u8, options: [*:0]const u8) ?*anyopaque {
    started_options = options;
    fake.note(.start, fake.sessions + 1);
    if (fake.start.next("ekk_pg_start") == 0) return null;
    fake.sessions += 1;
    const s = std.testing.allocator.create(Session) catch @panic("out of memory");
    s.* = .{ .id = fake.sessions, .fd = fake.next_fd };
    fake.next_fd = -1;
    return s;
}

/// PQconnectPoll: reads what the peer sent (the server's part of the
/// handshake), so a connected slot's peeking receive parks.
export fn ekk_pg_connect_poll(p: *anyopaque) c_int {
    const s = sessionOf(p);
    fake.note(.connect_poll, s.id);
    if (s.fd >= 0) {
        var buf: [256]u8 = undefined;
        while (c.read(s.fd, &buf, buf.len) > 0) {}
    }
    return fake.connect_poll.next("ekk_pg_connect_poll");
}

export fn ekk_pg_socket(p: *anyopaque) c_int {
    return sessionOf(p).fd;
}

/// PQfinish. The pool's contract: its duplicate is closed (NetClose has
/// completed) before the session ends. Closes "libpq's socket".
export fn ekk_pg_finish(p: *anyopaque) void {
    const s = sessionOf(p);
    fake.note(.finish, s.id);
    for (fake.dups[0..fake.ndups]) |d| {
        if (d.session == s.id and c.fcntl(d.fd, c.F.GETFD) != -1) {
            fake.dump();
            @panic("PQfinish before the pool closed its duplicate");
        }
    }
    if (s.fd >= 0) _ = close(s.fd);
    std.testing.allocator.destroy(s);
}

export fn ekk_dup(fd: c_int) c_int {
    const d = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (d >= 0) {
        // The session whose socket this is: the newest one with that fd.
        fake.dups[fake.ndups] = .{ .fd = d, .session = fake.sessions };
        fake.ndups += 1;
    }
    return d;
}

export fn ekk_pg_send(p: *anyopaque, q: Lean, err: *Lean) c_int {
    fake.note(.send, sessionOf(p).id);
    if (freeObj(q).kind != .query) @panic("ekk_pg_send got no query");
    const rc = fake.send.next("ekk_pg_send");
    err.* = if (rc == 1) newObj(.{ .kind = .err, .sqlstate = "54000".* }) else null;
    return rc;
}

export fn ekk_pg_flush(p: *anyopaque) c_int {
    fake.note(.flush, sessionOf(p).id);
    return fake.flush.next("ekk_pg_flush");
}

/// PQconsumeInput: reads what the peer sent, so the peeking receive parks
/// again.
export fn ekk_pg_consume(p: *anyopaque) c_int {
    const s = sessionOf(p);
    fake.note(.consume, s.id);
    var buf: [256]u8 = undefined;
    while (c.read(s.fd, &buf, buf.len) > 0) {}
    return fake.consume.next("ekk_pg_consume");
}

export fn ekk_pg_collect(p: *anyopaque, acc: *Lean) c_int {
    const s = sessionOf(p);
    fake.note(.collect, s.id);
    const rc = fake.collect.next("ekk_pg_collect");
    if ((acc.* != null) != s.closing) @panic("collect: an accumulated value the fake never made, or lost");
    if (acc.* == null) switch (rc) {
        0 => {},
        1 => acc.* = newObj(.{ .kind = .rows }),
        else => acc.* = newObj(.{ .kind = .err, .sqlstate = "0A000".* }),
    };
    s.closing = rc == 2 or (rc == 0 and s.closing);
    return rc;
}

export fn ekk_query_drop(q: Lean) void {
    _ = freeObj(q);
}

fn query() Lean {
    return newObj(.{ .kind = .query });
}

fn queryMs(ms: u32) Lean {
    return newObj(.{ .kind = .query, .timeout_ms = ms });
}

// ---- waiters ----

/// The depth of `deliver` calls on the stack, and its maximum.
var depth: u32 = 0;
var max_depth: u32 = 0;
/// A top-level `submit` of the test is running.
var in_submit = false;

const TestWaiter = struct {
    w: pg.Waiter = .{ .deliver = deliver },
    pool: *pg.Pool,
    /// The results delivered, in order (first 32), and how many.
    got: [32]Obj = undefined,
    n: usize = 0,
    /// The last result delivered.
    last: ?Obj = null,
    /// Deliveries made while a top-level `submit` was running.
    during_submit: usize = 0,
    /// Queries to submit again from `deliver`, one per delivery.
    again: usize = 0,
    /// Submitted from the first delivery, before this waiter's own resubmit.
    also: ?*TestWaiter = null,
    /// Stop the pool from the first delivery.
    stop_on_deliver: bool = false,
    /// The order of deliveries across waiters: each appends its tag.
    order: ?*std.ArrayList(u8) = null,
    tag: u8 = 0,

    fn deliver(w: *pg.Waiter, r: Lean) void {
        const self: *TestWaiter = @fieldParentPtr("w", w);
        depth += 1;
        defer depth -= 1;
        max_depth = @max(max_depth, depth);
        fake.note(.deliver, 0);
        // No case here delivers from inside a delivery; a chain that does
        // would recurse as deep as it is long, so it fails at once.
        if (depth > 1) {
            fake.dump();
            @panic("a delivery from inside a delivery");
        }
        const o = freeObj(r);
        if (self.n < self.got.len) self.got[self.n] = o;
        self.last = o;
        self.n += 1;
        if (in_submit) self.during_submit += 1;
        if (self.order) |list| list.append(std.testing.allocator, self.tag) catch @panic("out of memory");
        if (self.stop_on_deliver) {
            self.stop_on_deliver = false;
            self.pool.stop();
        }
        if (self.also) |o2| {
            self.also = null;
            self.pool.submit(&o2.w, query());
        }
        if (self.again > 0) {
            self.again -= 1;
            self.pool.submit(&self.w, query());
        }
    }

    fn submit(self: *TestWaiter) void {
        in_submit = true;
        defer in_submit = false;
        self.pool.submit(&self.w, query());
    }
};

// ---- fixture ----

const Fixture = struct {
    loop: ev.Loop = undefined,
    pool: pg.Pool = undefined,
    slots: [2]pg.Slot = undefined,
    /// The test's ends of the socketpairs it made.
    peers: [4]c.fd_t = undefined,
    npeers: usize = 0,

    fn init(self: *Fixture, nslots: usize) !void {
        try self.initBudgets(nslots, .{});
    }

    fn initBudgets(self: *Fixture, nslots: usize, budgets: pg.Budgets) !void {
        fake = .{};
        depth = 0;
        max_depth = 0;
        started_options = null;
        try self.loop.init(.{});
        self.pool.init(&self.loop, "fake", "fake options", budgets, self.slots[0..nslots], false);
    }

    /// A socketpair for the next session: returns the peer's end.
    fn pair(self: *Fixture) !c.fd_t {
        var sv: [2]c.fd_t = undefined;
        if (socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &sv) != 0) return error.Socketpair;
        const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
        for (sv) |fd| _ = c.fcntl(fd, c.F.SETFL, nonblock);
        fake.next_fd = sv[0];
        self.peers[self.npeers] = sv[1];
        self.npeers += 1;
        return sv[1];
    }

    /// Steps the loop until `pred(ctx)` holds.
    fn until(self: *Fixture, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !void {
        var steps: usize = 0;
        while (!pred(ctx)) : (steps += 1) {
            if (steps == max_steps) {
                fake.dump();
                return error.NoProgress;
            }
            try self.loop.poll(.zero);
        }
    }

    /// Steps the loop, each step blocking until an event, until `pred(ctx)`
    /// holds: for a state the pool's deadline timer produces. The cap on a
    /// step is the test's own bound (delay: test deadline: one wait for the
    /// pool's timer, which the budgets below set to milliseconds); running
    /// out fails the test.
    fn untilTimer(self: *Fixture, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !void {
        var steps: usize = 0;
        while (!pred(ctx)) : (steps += 1) {
            if (steps == 10) {
                fake.dump();
                return error.NoProgress;
            }
            try self.loop.poll(.fromMilliseconds(1000));
        }
    }

    /// Steps the loop a few times: for checks that nothing happens.
    fn idle(self: *Fixture) !void {
        for (0..3) |_| try self.loop.poll(.zero);
    }

    fn allDisconnected(self: *Fixture) bool {
        for (self.pool.slots) |*s| if (s.state != .disconnected) return false;
        return true;
    }

    /// Stops the pool, waits for every slot to end its session and checks
    /// that every script was used, every Lean value dropped or delivered and
    /// every descriptor closed.
    fn deinit(self: *Fixture) !void {
        self.pool.stop();
        try self.until(self, allDisconnected);
        self.loop.deinit();
        for (self.peers[0..self.npeers]) |fd| _ = close(fd);
        try std.testing.expect(fake.scriptsDone());
        try std.testing.expectEqual(@as(i64, 0), fake.live);
        for (fake.dups[0..fake.ndups]) |d| try std.testing.expectEqual(@as(c_int, -1), c.fcntl(d.fd, c.F.GETFD));
        // Every session made was ended once.
        try std.testing.expectEqual(@as(usize, fake.sessions), fake.count.get(.finish));
    }
};

/// Fills `fd`'s send buffer: it is not writable until its peer reads.
fn fill(fd: c.fd_t) !void {
    const buf: [4096]u8 = @splat(0);
    var i: usize = 0;
    while (c.write(fd, &buf, buf.len) > 0) : (i += 1) {
        if (i == 100_000) return error.NeverFull;
    }
}

/// Reads everything the peer has.
fn drain(fd: c.fd_t) void {
    var buf: [4096]u8 = undefined;
    while (c.read(fd, &buf, buf.len) > 0) {}
}

fn poke(fd: c.fd_t) !void {
    if (c.write(fd, "x", 1) != 1) return error.Write;
}

fn kinds(events: []const Event, buf: []Kind) []Kind {
    for (events, 0..) |e, i| buf[i] = e.kind;
    return buf[0..events.len];
}

fn expectKinds(from: usize, expected: []const Kind) !void {
    var buf: [256]Kind = undefined;
    std.testing.expectEqualSlices(Kind, expected, kinds(fake.since(from), &buf)) catch |e| {
        fake.dump();
        return e;
    };
}

fn slot0(fx: *Fixture) *pg.Slot {
    return &fx.pool.slots[0];
}

const delivered = struct {
    fn f(x: *TestWaiter) bool {
        return x.n > 0;
    }
}.f;

/// Connects slot 0 synchronously and leaves its query sent with output left
/// to flush (flush = 1) on a socket that is not writable: the receive and
/// the send poll are both outstanding. Returns the peer.
fn busyWithBothPolls(fx: *Fixture, w: *TestWaiter) !c.fd_t {
    const peer = try fx.pair();
    try fill(fake.next_fd);
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{3});
    fake.send.push(&.{0});
    fake.flush.push(&.{1});
    w.submit();
    const s = slot0(fx);
    try std.testing.expectEqual(.busy, s.state);
    try std.testing.expect(s.rarmed and s.warmed and s.flushing);
    // The duplicate is neither readable nor writable, so neither poll can
    // complete until the test acts.
    var pfd = [1]c.pollfd{.{ .fd = s.fd, .events = c.POLL.IN | c.POLL.OUT, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));
    const before = fake.calls;
    try fx.idle();
    try std.testing.expectEqual(before, fake.calls); // nothing is ready
    try std.testing.expectEqual(@as(usize, 0), w.n);
    return peer;
}

// ---- (a) a partial flush, both polls outstanding ----

test "a: the write completion arrives after the slot went idle and changes nothing" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try busyWithBothPolls(&fx, &w);
    const s = slot0(&fx);

    // The results arrive while the socket is still unwritable: the receive
    // finishes the flush and the query; the slot goes idle with its send poll
    // still outstanding.
    fake.consume.push(&.{1});
    fake.flush.push(&.{0});
    fake.collect.push(&.{1});
    var mark = fake.calls;
    try poke(peer);
    try fx.until(&w, delivered);
    try expectKinds(mark, &.{ .consume, .flush, .collect, .deliver });
    try std.testing.expectEqual(.idle, s.state);
    try std.testing.expect(s.warmed and s.rarmed and !s.flushing);
    try std.testing.expectEqual(.rows, w.got[0].kind);

    // Now the socket becomes writable: the stale send poll completes on the
    // idle slot and calls nothing.
    mark = fake.calls;
    drain(peer);
    try fx.until(s, struct {
        fn f(x: *pg.Slot) bool {
            return !x.warmed;
        }
    }.f);
    try expectKinds(mark, &[_]Kind{});
    try std.testing.expectEqual(.idle, s.state);
    try std.testing.expect(s.rarmed);
    try std.testing.expectEqual(@as(usize, 1), w.n);

    try fx.deinit();
}

test "a: output collect queued (2) is flushed, then the slot waits for its results" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try busyWithBothPolls(&fx, &w);
    const s = slot0(&fx);

    // The query's results arrive: the receive finishes the flush, collect
    // keeps the answer and queues output that does not all go out.
    fake.consume.push(&.{1});
    fake.flush.push(&.{ 0, 1 });
    fake.collect.push(&.{2});
    var mark = fake.calls;
    try poke(peer);
    try fx.until(&fake, struct {
        fn f(x: *Fake) bool {
            return x.count.get(.collect) == 1;
        }
    }.f);
    try expectKinds(mark, &.{ .consume, .flush, .collect, .flush });
    try std.testing.expectEqual(.busy, s.state);
    try std.testing.expect(s.flushing and s.warmed and s.rarmed);
    try std.testing.expectEqual(@as(usize, 0), w.n);

    // Writable: the send poll flushes the rest.
    fake.flush.push(&.{0});
    mark = fake.calls;
    drain(peer);
    try fx.until(s, struct {
        fn f(x: *pg.Slot) bool {
            return !x.warmed;
        }
    }.f);
    try expectKinds(mark, &.{.flush});
    try std.testing.expect(!s.flushing);

    // Its results arrive: the query is answered with the error kept.
    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    mark = fake.calls;
    try poke(peer);
    try fx.until(&w, delivered);
    try expectKinds(mark, &.{ .consume, .collect, .deliver });
    try std.testing.expectEqual(.idle, s.state);
    try std.testing.expectEqual(.err, w.got[0].kind);
    try fx.deinit();
}

test "a: a connection lost after collect has the answer (2) delivers that answer, not 08006" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try sentAndBusy(&fx, &w, query());
    fake.consume.push(&.{ 1, 0 });
    fake.flush.push(&.{0});
    fake.collect.push(&.{2});
    try poke(peer);
    try fx.until(&fake, struct {
        fn f(x: *Fake) bool {
            return x.count.get(.collect) == 1;
        }
    }.f);
    try std.testing.expectEqual(@as(usize, 0), w.n);
    // The Close's results never come: the connection fails.
    const mark = fake.calls;
    try poke(peer);
    try fx.until(&w, delivered);
    try expectKinds(mark, &.{ .consume, .deliver });
    try std.testing.expectEqual(.err, w.got[0].kind);
    try std.testing.expectEqualSlices(u8, "0A000", &w.got[0].sqlstate);
    try fx.deinit();
}

test "a: a deadline or the drain's end during the Close (2) delivers the known error, not 57014, and closes the session" {
    // Forced order, no clock race: collect returns 2 (the query's error
    // known, the Close of its forgotten statement flushed), and the Close's
    // reply is held, since the fake's collect runs only when the peer sends
    // a byte and the test sends none. With the slot answered-but-closing,
    // the query's deadline is made due and the timer's callback run (as the
    // loop would run it), or the drain ends (`abort`).
    for ([_]bool{ false, true }) |drain_end| {
        var fx: Fixture = .{};
        try fx.initBudgets(1, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
        var w: TestWaiter = .{ .pool = &fx.pool };
        const peer = try sentAndBusy(&fx, &w, query());
        const s = slot0(&fx);
        fake.consume.push(&.{1});
        fake.flush.push(&.{0});
        fake.collect.push(&.{2});
        try poke(peer);
        try fx.until(&fake, struct {
            fn f(x: *Fake) bool {
                return x.count.get(.collect) == 1;
            }
        }.f);
        // The path under test: busy, answered, the Close's reply not in.
        try std.testing.expect(s.state == .busy and s.answered and s.acc != null);
        try std.testing.expectEqual(@as(usize, 0), w.n);
        const mark = fake.calls;
        if (drain_end) {
            fx.pool.stop();
            fx.pool.abort();
        } else {
            w.w.deadline = .zero;
            try std.testing.expect(fx.loop.clearTimer(&fx.pool.timer));
            fx.pool.timer.c.callback.?(&fx.loop, &fx.pool.timer.c);
        }
        try fx.until(&fx, Fixture.allDisconnected);
        // One delivery, the query's own error; no read, the session ended.
        try expectKinds(mark, &.{ .deliver, .finish });
        try std.testing.expectEqual(@as(usize, 1), w.n);
        try std.testing.expectEqual(.err, w.got[0].kind);
        try std.testing.expectEqualSlices(u8, "0A000", &w.got[0].sqlstate);
        try std.testing.expectError(error.Write, poke(peer));
        try fx.deinit();
    }
}

test "a: a query sent while the stale send poll is outstanding uses that poll" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try busyWithBothPolls(&fx, &w);
    const s = slot0(&fx);
    fake.consume.push(&.{1});
    fake.flush.push(&.{0});
    fake.collect.push(&.{1});
    try poke(peer);
    try fx.until(&w, delivered);
    try std.testing.expect(s.warmed);

    // The next query leaves output too; arm(.send) finds the poll armed.
    fake.send.push(&.{0});
    fake.flush.push(&.{1});
    w.submit();
    try std.testing.expectEqual(.busy, s.state);
    try std.testing.expect(s.warmed and s.flushing);

    // Writable: the old poll's completion flushes the new query's output.
    fake.flush.push(&.{0});
    var mark = fake.calls;
    drain(peer);
    try fx.until(s, struct {
        fn f(x: *pg.Slot) bool {
            return !x.warmed;
        }
    }.f);
    try expectKinds(mark, &.{.flush});
    try std.testing.expect(!s.flushing);

    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    mark = fake.calls;
    try poke(peer);
    try fx.until(&w, struct {
        fn f(x: *TestWaiter) bool {
            return x.n == 2;
        }
    }.f);
    try expectKinds(mark, &.{ .consume, .collect, .deliver });
    try fx.deinit();
}

test "a: a delivery that submits at once runs the next query on the same slot" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool, .again = 1 };
    const peer = try busyWithBothPolls(&fx, &w);
    const s = slot0(&fx);
    // The receive callback delivers; deliver submits the next query, which
    // is sent from inside the callback and leaves output (flush = 1).
    fake.consume.push(&.{1});
    fake.send.push(&.{0});
    fake.flush.push(&.{ 0, 1 });
    fake.collect.push(&.{1});
    const mark = fake.calls;
    try poke(peer);
    try fx.until(&w, delivered);
    try expectKinds(mark, &.{ .consume, .flush, .collect, .deliver, .send, .flush });
    try std.testing.expectEqual(.busy, s.state);
    try std.testing.expect(s.warmed and s.rarmed and s.flushing);

    fake.flush.push(&.{0});
    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    drain(peer);
    try poke(peer);
    try fx.until(&w, struct {
        fn f(x: *TestWaiter) bool {
            return x.n == 2;
        }
    }.f);
    try std.testing.expectEqual(.idle, s.state);
    try fx.deinit();
}

test "a: a stop from the delivery ends the session with both polls outstanding" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool, .stop_on_deliver = true };
    const peer = try busyWithBothPolls(&fx, &w);
    const s = slot0(&fx);
    fake.consume.push(&.{1});
    fake.flush.push(&.{0});
    fake.collect.push(&.{1});
    const mark = fake.calls;
    try poke(peer);
    try fx.until(&fx, Fixture.allDisconnected);
    // The send poll was still outstanding: teardown cancels both, closes the
    // duplicate, then ends the session (ekk_pg_finish checks the order).
    try expectKinds(mark, &.{ .consume, .flush, .collect, .deliver, .finish });
    try std.testing.expect(!s.rarmed and !s.warmed and s.fd == -1);
    try std.testing.expectEqual(@as(usize, 1), w.n);
    try fx.deinit();
}

test "a: writable while busy, a second partial flush arms the send poll again" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try busyWithBothPolls(&fx, &w);
    const s = slot0(&fx);
    fake.flush.push(&.{ 1, 0 });
    var mark = fake.calls;
    drain(peer);
    try fx.until(s, struct {
        fn f(x: *pg.Slot) bool {
            return !x.flushing and !x.warmed;
        }
    }.f);
    try expectKinds(mark, &.{ .flush, .flush });
    try std.testing.expectEqual(.busy, s.state);

    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    mark = fake.calls;
    try poke(peer);
    try fx.until(&w, delivered);
    try expectKinds(mark, &.{ .consume, .collect, .deliver });
    try fx.deinit();
}

test "a: readable and writable before the loop runs: one flush, one delivery, either order" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try busyWithBothPolls(&fx, &w);
    const s = slot0(&fx);
    fake.consume.push(&.{1});
    fake.flush.push(&.{0});
    fake.collect.push(&.{1});
    drain(peer);
    try poke(peer);
    try fx.until(s, struct {
        fn f(x: *pg.Slot) bool {
            return x.state == .idle and !x.warmed;
        }
    }.f);
    try std.testing.expectEqual(@as(usize, 1), fake.count.get(.collect));
    try std.testing.expectEqual(@as(usize, 2), fake.count.get(.flush));
    try std.testing.expectEqual(@as(usize, 1), w.n);
    try fx.deinit();
}

// ---- (c) the session ends while both polls are outstanding (COPY) ----

test "c: COPY ends the session with both polls outstanding; the next query gets a new session" {
    var fx: Fixture = .{};
    try fx.init(1);
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try busyWithBothPolls(&fx, &w);
    const s = slot0(&fx);
    // Input arrives with output still pending (flush = 1 again, the send
    // poll stays armed); collect reports COPY: the session must close.
    fake.consume.push(&.{1});
    fake.flush.push(&.{1});
    fake.collect.push(&.{-1});
    var mark = fake.calls;
    try poke(peer);
    try fx.until(&w, delivered);
    try std.testing.expectEqualSlices(u8, "0A000", &w.got[0].sqlstate);
    try fx.until(&fx, Fixture.allDisconnected);
    try expectKinds(mark, &.{ .consume, .flush, .collect, .deliver, .finish });
    try std.testing.expect(s.pg == null and s.fd == -1 and !s.rarmed and !s.warmed);

    // The next query opens session 2, never touching session 1.
    _ = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{3});
    fake.send.push(&.{0});
    fake.flush.push(&.{0});
    mark = fake.calls;
    w.submit();
    try expectKinds(mark, &.{ .start, .connect_poll, .send, .flush });
    for (fake.since(mark)) |e| try std.testing.expectEqual(@as(u32, 2), e.session);
    const peer2 = fx.peers[1];
    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    try poke(peer2);
    try fx.until(&w, struct {
        fn f(x: *TestWaiter) bool {
            return x.n == 2;
        }
    }.f);
    try std.testing.expectEqual(.rows, w.got[1].kind);
    try fx.deinit();
}

// ---- (d) synchronous chains of failing queries ----

const chain = 10_000;

/// Another connection's work on the same loop: a receive whose bytes are
/// there before a chain starts. Its callback records how many results the
/// chain had delivered when the loop ran it.
const Bystander = struct {
    fds: [2]c.fd_t = undefined,
    recv: ev.NetRecv = undefined,
    buf: [1]u8 = undefined,
    iov: [1]zio.os.iovec = undefined,
    closer: ev.NetClose = undefined,
    closed: bool = false,
    watched: *const TestWaiter,
    seen: ?usize = null,

    fn start(self: *Bystander, loop: *ev.Loop) !void {
        if (socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &self.fds) != 0) return error.Socketpair;
        const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
        for (self.fds) |fd| _ = c.fcntl(fd, c.F.SETFL, nonblock);
        try poke(self.fds[1]);
        self.recv = ev.NetRecv.init(self.fds[0], .fromSlice(&self.buf, &self.iov), .{});
        self.recv.c.callback = received;
        self.recv.c.userdata = self;
        loop.add(&self.recv.c);
    }

    fn received(_: *ev.Loop, comp: *ev.Completion) void {
        const self: *Bystander = @ptrCast(@alignCast(comp.userdata.?));
        _ = self.recv.getResult() catch @panic("the bystander's receive failed");
        self.seen = self.watched.n;
    }

    /// Unregisters and closes the loop's end, then the peer's.
    fn finish(self: *Bystander, fx: *Fixture) !void {
        self.closer = ev.NetClose.init(self.fds[0]);
        self.closer.c.callback = closedCb;
        self.closer.c.userdata = self;
        fx.loop.add(&self.closer.c);
        try fx.until(self, struct {
            fn f(x: *Bystander) bool {
                return x.closed;
            }
        }.f);
        _ = close(self.fds[1]);
    }

    fn closedCb(_: *ev.Loop, comp: *ev.Completion) void {
        const self: *Bystander = @ptrCast(@alignCast(comp.userdata.?));
        self.closed = true;
    }
};

fn chainDone(w: *TestWaiter) bool {
    return w.n >= chain;
}

/// A chain of `chain` failing queries asked from one `submit`, each asked
/// again from its error, with another connection's receive ready on the same
/// loop before it starts (item rtkla3): `pg.chain_inline` results are
/// delivered inside the `submit`, the rest from later turns of the loop, the
/// receive's callback runs while the chain is still going, every result is
/// delivered exactly once, and no delivery happens inside another.
fn yieldingChain(fx: *Fixture) !void {
    var w: TestWaiter = .{ .pool = &fx.pool, .again = chain - 1 };
    var b: Bystander = .{ .watched = &w };
    try b.start(&fx.loop);
    w.submit();
    try std.testing.expectEqual(@as(usize, pg.chain_inline), w.n);
    try std.testing.expectEqual(@as(usize, pg.chain_inline), w.during_submit);
    try std.testing.expect(fx.pool.cont_armed);
    try fx.until(&w, chainDone);
    // The receive was ready before the chain began, and ran after its
    // inline part and before its end.
    const seen = b.seen orelse return error.BystanderNeverRan;
    try std.testing.expect(seen >= pg.chain_inline and seen < chain);
    try fx.idle();
    try std.testing.expectEqual(@as(usize, chain), w.n);
    try std.testing.expect(!fx.pool.cont_armed);
    try std.testing.expectEqualSlices(u8, "08006", &w.got[31].sqlstate);
    try std.testing.expectEqual(@as(u32, 1), max_depth);
    try b.finish(fx);
}

test "d: zero slots: a long chain of failures yields to the loop's other ready work" {
    var fx: Fixture = .{};
    try fx.init(0);
    try yieldingChain(&fx);
    try fx.deinit();
}

test "d: the database down: a long chain of connect failures yields to the loop's other ready work" {
    // Both ways a connect fails at once: PQconnectStart fails (no session),
    // or the first PQconnectPoll does.
    for ([_]c_int{ 0, 1 }) |start| {
        var fx: Fixture = .{};
        try fx.init(2);
        fake.start.repeat = start;
        fake.connect_poll.repeat = 0;
        try yieldingChain(&fx);
        try std.testing.expectEqual(@as(usize, chain), fake.count.get(.start));
        try std.testing.expectEqual(@as(usize, if (start == 1) chain else 0), fake.count.get(.finish));
        fake.start.repeat = null;
        fake.connect_poll.repeat = null;
        fx.pool.stop();
        fx.loop.deinit();
        try std.testing.expectEqual(@as(i64, 0), fake.live);
    }
}

test "d: a submit while a yielded chain waits queues behind it, not ahead of the loop's other work" {
    // Another connection's callback submits in the turn the chain yielded
    // in: the pool answers nothing more until the chain's own turn.
    var fx: Fixture = .{};
    try fx.init(0);
    var w: TestWaiter = .{ .pool = &fx.pool, .again = chain - 1 };
    var v: TestWaiter = .{ .pool = &fx.pool };
    w.submit();
    try std.testing.expectEqual(@as(usize, pg.chain_inline), w.n);
    v.submit();
    try std.testing.expectEqual(@as(usize, pg.chain_inline), w.n);
    try std.testing.expectEqual(@as(usize, 0), v.n);
    try fx.until(&w, chainDone);
    try fx.idle();
    try std.testing.expectEqual(@as(usize, chain), w.n);
    try std.testing.expectEqual(@as(usize, 1), v.n);
    try std.testing.expectEqualSlices(u8, "08006", &v.got[0].sqlstate);
    try std.testing.expectEqual(@as(u32, 1), max_depth);
    try fx.deinit();
}

test "d: the drain's end while a yielded chain waits answers the rest of it at once" {
    var fx: Fixture = .{};
    try fx.init(0);
    var w: TestWaiter = .{ .pool = &fx.pool, .again = chain - 1 };
    w.submit();
    try std.testing.expectEqual(@as(usize, pg.chain_inline), w.n);
    try std.testing.expect(fx.pool.cont_armed);
    fx.pool.abort();
    try std.testing.expectEqual(@as(usize, chain), w.n);
    try std.testing.expectEqualSlices(u8, "57014", &w.last.?.sqlstate);
    // The turn already on its way finds nothing left.
    try fx.until(&fx.pool, struct {
        fn f(x: *pg.Pool) bool {
            return !x.cont_armed;
        }
    }.f);
    try fx.idle();
    try std.testing.expectEqual(@as(usize, chain), w.n);
    try std.testing.expectEqual(@as(u32, 1), max_depth);
    try fx.deinit();
}

test "d: after the drain's end a chain runs to its end inside the submit" {
    // serve.zig closes every connection right after `abort`, so the pool
    // must not leave any of a chain for a later turn then.
    var fx: Fixture = .{};
    try fx.init(0);
    fx.pool.abort();
    var w: TestWaiter = .{ .pool = &fx.pool, .again = chain - 1 };
    w.submit();
    try std.testing.expectEqual(@as(usize, chain), w.n);
    try std.testing.expectEqual(@as(usize, chain), w.during_submit);
    try std.testing.expect(!fx.pool.cont_armed);
    try std.testing.expectEqualSlices(u8, "57014", &w.got[31].sqlstate);
    try std.testing.expectEqual(@as(u32, 1), max_depth);
    try fx.deinit();
}

test "d: two chains submitted during one dispatch alternate in FIFO order" {
    var fx: Fixture = .{};
    try fx.init(0);
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var b: TestWaiter = .{ .pool = &fx.pool, .again = 3, .order = &order, .tag = 'b' };
    var a: TestWaiter = .{ .pool = &fx.pool, .again = 3, .also = &b, .order = &order, .tag = 'a' };
    a.submit();
    try std.testing.expectEqualStrings("abababab", order.items);
    try std.testing.expectEqual(@as(u32, 1), max_depth);
    try fx.deinit();
}

test "d: a connect that fails after a readiness completion is delivered from the loop" {
    var fx: Fixture = .{};
    try fx.init(1);
    const peer = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{ 1, 0 }); // wait to read, then fail
    var w: TestWaiter = .{ .pool = &fx.pool };
    w.submit();
    try std.testing.expectEqual(@as(usize, 0), w.n);
    try std.testing.expectEqual(.connecting, slot0(&fx).state);
    try poke(peer);
    try fx.until(&w, delivered);
    try std.testing.expectEqual(@as(usize, 0), w.during_submit);
    try std.testing.expectEqualSlices(u8, "08006", &w.got[0].sqlstate);
    try std.testing.expectEqual(.disconnected, slot0(&fx).state);
    try fx.deinit();
}

// ---- (e) one connect in flight per pool ----

fn slotIs(comptime i: usize, comptime state: anytype) fn (*Fixture) bool {
    return struct {
        fn f(fx: *Fixture) bool {
            return fx.pool.slots[i].state == state;
        }
    }.f;
}

test "e: one connect serves every query waiting; its failure fails each of them once" {
    var fx: Fixture = .{};
    try fx.init(2);
    const peer = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{ 1, 0 }); // wait to read, then fail
    var ws = [_]TestWaiter{ .{ .pool = &fx.pool }, .{ .pool = &fx.pool }, .{ .pool = &fx.pool } };
    for (&ws) |*w| w.submit();
    // Two slots, three queries: one connect, on slot 0.
    try std.testing.expectEqual(@as(usize, 1), fake.count.get(.start));
    try std.testing.expectEqual(.connecting, fx.pool.slots[0].state);
    try std.testing.expectEqual(.disconnected, fx.pool.slots[1].state);
    const mark = fake.calls;
    try poke(peer);
    try fx.until(&ws[2], delivered);
    try expectKinds(mark, &.{ .connect_poll, .deliver, .deliver, .deliver, .finish });
    for (&ws) |*w| {
        try std.testing.expectEqual(@as(usize, 1), w.n);
        try std.testing.expectEqualSlices(u8, "08006", &w.got[0].sqlstate);
    }
    try std.testing.expect(fx.allDisconnected());
    try fx.idle();
    try std.testing.expectEqual(@as(usize, 1), fake.count.get(.start)); // no reconnect
    try fx.deinit();
}

test "e: a query submitted from a failed connect's delivery waits for the next connect" {
    var fx: Fixture = .{};
    try fx.init(1);
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    const peer = try fx.pair();
    fake.start.push(&.{ 1, 1 });
    // Connect 1 waits to read, then fails; connect 2 fails at once.
    fake.connect_poll.push(&.{ 1, 0, 0 });
    var a: TestWaiter = .{ .pool = &fx.pool, .again = 1, .order = &order, .tag = 'a' };
    var b: TestWaiter = .{ .pool = &fx.pool, .order = &order, .tag = 'b' };
    a.submit();
    b.submit();
    try poke(peer);
    try fx.until(&a, struct {
        fn f(x: *TestWaiter) bool {
            return x.n == 2;
        }
    }.f);
    // a's second query was not failed by connect 1: b, waiting for connect
    // 1, got its answer first, and connect 2 answered a again.
    try std.testing.expectEqualStrings("aba", order.items);
    try std.testing.expectEqual(@as(usize, 2), fake.count.get(.start));
    try std.testing.expectEqualSlices(u8, "08006", &a.got[1].sqlstate);
    try std.testing.expectEqual(@as(u32, 1), max_depth);
    try fx.deinit();
}

test "e: a connect that succeeds serves the queue; the next connect starts only after it" {
    var fx: Fixture = .{};
    try fx.init(2);
    _ = try fx.pair(); // session 1
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{1});
    var a: TestWaiter = .{ .pool = &fx.pool };
    var b: TestWaiter = .{ .pool = &fx.pool };
    var d: TestWaiter = .{ .pool = &fx.pool };
    a.submit();
    b.submit();
    d.submit();
    try std.testing.expectEqual(@as(usize, 1), fake.count.get(.start));

    // Session 1 connects and runs a, the queue's head; b and d still wait,
    // so the pool starts connect 2 (session 2 waits to read).
    _ = try fx.pair(); // session 2
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{ 3, 1 });
    fake.send.push(&.{0});
    fake.flush.push(&.{0});
    var mark = fake.calls;
    try poke(fx.peers[0]);
    try fx.until(&fx, slotIs(1, .connecting));
    try expectKinds(mark, &.{ .connect_poll, .send, .flush, .start, .connect_poll });
    try std.testing.expectEqual(.busy, fx.pool.slots[0].state);

    // a's result: slot 0 goes idle and runs b; d waits for connect 2.
    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    fake.send.push(&.{0});
    fake.flush.push(&.{0});
    mark = fake.calls;
    try poke(fx.peers[0]);
    try fx.until(&a, delivered);
    try expectKinds(mark, &.{ .consume, .collect, .deliver, .send, .flush });
    try std.testing.expectEqual(.rows, a.got[0].kind);
    try std.testing.expectEqual(@as(usize, 0), d.n);

    // Session 2 connects and runs d.
    fake.connect_poll.push(&.{3});
    fake.send.push(&.{0});
    fake.flush.push(&.{0});
    mark = fake.calls;
    try poke(fx.peers[1]);
    try fx.until(&fx, slotIs(1, .busy));
    try expectKinds(mark, &.{ .connect_poll, .send, .flush });

    fake.consume.push(&.{ 1, 1 });
    fake.collect.push(&.{ 1, 1 });
    try poke(fx.peers[0]);
    try poke(fx.peers[1]);
    try fx.until(&d, delivered);
    try fx.until(&b, delivered);
    try std.testing.expectEqual(.rows, b.got[0].kind);
    try std.testing.expectEqual(.rows, d.got[0].kind);
    try std.testing.expectEqual(@as(usize, 2), fake.count.get(.start));
    try fx.deinit();
}

// ---- (f) deadlines ----

/// Budgets for the deadline tests: the one under test in milliseconds, the
/// others far beyond the test (delay: external deadline: the database
/// budgets the pool enforces, here set by the test).
const far: u32 = 600_000;

fn sentAndBusy(fx: *Fixture, w: *TestWaiter, q: Lean) !c.fd_t {
    const peer = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{3});
    fake.send.push(&.{0});
    fake.flush.push(&.{0});
    in_submit = true;
    fx.pool.submit(&w.w, q);
    in_submit = false;
    try std.testing.expectEqual(.busy, slot0(fx).state);
    return peer;
}

test "f: a query whose deadline passes in the queue fails with 57014, unsent and unlinked" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = 10, .query_max_ms = far, .connect_ms = far });
    const peer = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{ 1, 3 }); // wait to read, then connected
    var a: TestWaiter = .{ .pool = &fx.pool };
    a.submit();
    try std.testing.expectEqual(.connecting, slot0(&fx).state);
    try fx.untilTimer(&a, delivered);
    try std.testing.expectEqual(.err, a.got[0].kind);
    try std.testing.expectEqualSlices(u8, "57014", &a.got[0].sqlstate);
    try std.testing.expect(fx.pool.head == null and fx.pool.tail == null);
    try std.testing.expectEqual(@as(usize, 0), fake.count.get(.send));
    // The connect goes on; its connection finds no query waiting.
    try poke(peer);
    try fx.until(&fx, slotIs(0, .idle));
    try std.testing.expectEqual(@as(usize, 1), a.n);
    try std.testing.expectEqual(@as(usize, 0), fake.count.get(.send));
    try fx.deinit();
}

test "f: an expired query among others: only it leaves the queue, the others keep their order" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    const peer = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{ 1, 3 });
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var a: TestWaiter = .{ .pool = &fx.pool, .order = &order, .tag = 'a' };
    var b: TestWaiter = .{ .pool = &fx.pool, .order = &order, .tag = 'b' };
    var d: TestWaiter = .{ .pool = &fx.pool, .order = &order, .tag = 'd' };
    a.submit();
    fx.pool.submit(&b.w, queryMs(10));
    d.submit();
    try fx.untilTimer(&b, delivered);
    try std.testing.expectEqualSlices(u8, "57014", &b.got[0].sqlstate);
    try std.testing.expect(fx.pool.head == &a.w and a.w.next == &d.w and fx.pool.tail == &d.w);
    // The connection runs a, then d.
    fake.send.push(&.{ 0, 0 });
    fake.flush.push(&.{ 0, 0 });
    fake.consume.push(&.{ 1, 1 });
    fake.collect.push(&.{ 1, 1 });
    try poke(peer);
    try fx.until(&fx, slotIs(0, .busy));
    try poke(peer);
    try fx.until(&a, delivered);
    try poke(peer);
    try fx.until(&d, delivered);
    try std.testing.expectEqualStrings("bad", order.items);
    try fx.deinit();
}

test "f: a busy query's deadline abandons it with 57014; its session is closed and never reused" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = 10, .query_max_ms = far, .connect_ms = far });
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try sentAndBusy(&fx, &w, query());
    try std.testing.expectEqualStrings("fake options", std.mem.span(started_options.?));
    var mark = fake.calls;
    try fx.untilTimer(&w, delivered);
    try std.testing.expectEqual(.abandoned, w.got[0].kind);
    try std.testing.expectEqualSlices(u8, "57014", &w.got[0].sqlstate);
    try fx.until(&fx, Fixture.allDisconnected);
    // No PQcancel, no read: the session ends without waiting for the server.
    try expectKinds(mark, &.{ .deliver, .finish });
    // The session's socket is closed: a late answer has nowhere to go.
    try std.testing.expectError(error.Write, poke(peer));
    try std.testing.expectEqual(@as(usize, 1), w.n);

    // The next query gets session 2.
    _ = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{3});
    fake.send.push(&.{0});
    fake.flush.push(&.{0});
    mark = fake.calls;
    fx.pool.submit(&w.w, queryMs(far));
    for (fake.since(mark)) |e| try std.testing.expectEqual(@as(u32, 2), e.session);
    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    try poke(fx.peers[1]);
    try fx.until(&w, struct {
        fn f(x: *TestWaiter) bool {
            return x.n == 2;
        }
    }.f);
    try std.testing.expectEqual(.rows, w.got[1].kind);
    try fx.deinit();
}

test "f: a connect's deadline fails the queries waiting with 08006" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = far, .query_max_ms = far, .connect_ms = 10 });
    _ = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{1}); // waits to read; the server never answers
    var a: TestWaiter = .{ .pool = &fx.pool };
    var b: TestWaiter = .{ .pool = &fx.pool };
    a.submit();
    b.submit();
    try fx.untilTimer(&b, delivered);
    for ([_]*TestWaiter{ &a, &b }) |x| {
        try std.testing.expectEqual(@as(usize, 1), x.n);
        try std.testing.expectEqual(.err, x.got[0].kind);
        try std.testing.expectEqualSlices(u8, "08006", &x.got[0].sqlstate);
    }
    try fx.until(&fx, Fixture.allDisconnected);
    try std.testing.expectEqual(@as(usize, 1), fake.count.get(.finish));
    try std.testing.expect(fx.pool.attempt == null);
    try fx.deinit();
}

test "f: a waiter's own earlier deadline ends it while the connect runs on" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = 10, .query_max_ms = far, .connect_ms = far });
    const peer = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{ 1, 3 });
    var a: TestWaiter = .{ .pool = &fx.pool };
    a.submit();
    try fx.untilTimer(&a, delivered);
    try std.testing.expectEqualSlices(u8, "57014", &a.got[0].sqlstate);
    try std.testing.expectEqual(.connecting, slot0(&fx).state);
    try poke(peer);
    try fx.until(&fx, slotIs(0, .idle));
    try fx.deinit();
}

test "f: an expiry that comes after the completion changes nothing" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    var w: TestWaiter = .{ .pool = &fx.pool };
    const peer = try sentAndBusy(&fx, &w, query());
    try std.testing.expect(fx.pool.timer_due != null);
    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    try poke(peer);
    try fx.until(&w, delivered);
    // Nothing runs: the timer is off.
    try std.testing.expect(fx.pool.timer_due == null);
    // A timer callback that arrives now (one already on its way when the
    // completion cleared the timer) finds nothing due.
    const mark = fake.calls;
    fx.pool.timer.c.callback.?(&fx.loop, &fx.pool.timer.c);
    try expectKinds(mark, &[_]Kind{});
    try std.testing.expectEqual(.idle, slot0(&fx).state);
    try std.testing.expectEqual(@as(usize, 1), w.n);
    try std.testing.expect(fx.pool.timer_due == null);

    // And one that arrives while another query runs, not yet due, leaves
    // that query running and the timer armed for it.
    fake.send.push(&.{0});
    fake.flush.push(&.{0});
    w.submit();
    // The loop dequeues an early callback: the timer is no longer
    // registered when the callback runs, and the callback re-arms it.
    try std.testing.expect(fx.loop.clearTimer(&fx.pool.timer));
    fx.pool.timer.c.callback.?(&fx.loop, &fx.pool.timer.c);
    try std.testing.expectEqual(.busy, slot0(&fx).state);
    try std.testing.expect(fx.pool.timer_due != null and fx.pool.timer_due.?.value == w.w.deadline.value);
    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    try poke(peer);
    try fx.until(&w, struct {
        fn f(x: *TestWaiter) bool {
            return x.n == 2;
        }
    }.f);
    try std.testing.expectEqual(.rows, w.got[1].kind);
    try fx.deinit();
}

// The deadline timer's own lifecycle (`Pool.rearm`, `Pool.arm`): the tests
// below force each fire with hooks instead of waiting for the clock. A fire
// is forced by moving the registered timer's deadline into the past through
// the loop; a callback is held "on its way" by giving the timer a null
// callback, so the loop hands the fired completion out through
// `nextDispatched` instead of calling it (zio's `Completion.callback`), and
// the test calls the pool's callback on it later, as the loop would.

/// Makes the pool's registered timer fire at the loop's next poll.
fn fireTimer(fx: *Fixture) void {
    fx.loop.setTimer(&fx.pool.timer, .{ .deadline = .zero });
}

/// The pool's timer is registered with the loop and has not fired.
fn timerRegistered(fx: *Fixture) bool {
    return fx.pool.timer.c.loadState().phase == .running and !fx.pool.timer.c.has_result;
}

/// The pool's timer is registered for `timer_due` and points back at the
/// pool's callback `cb`.
fn expectArmedFor(fx: *Fixture, cb: *const ev.Completion.CallbackFn, due_at: zio.Timestamp) !void {
    try std.testing.expect(timerRegistered(fx));
    try std.testing.expect(fx.pool.timer_due != null and fx.pool.timer_due.?.value == due_at.value);
    try std.testing.expect(fx.pool.timer.timeout == .deadline and fx.pool.timer.timeout.deadline.value == due_at.value);
    try std.testing.expect(fx.pool.timer.c.callback == cb);
    try std.testing.expect(fx.pool.timer.c.userdata == @as(*anyopaque, &fx.pool));
}

/// Fires the timer and holds its callback: returns the pool's callback,
/// with the fired (dead) completion out of the loop and not yet called.
fn holdTimer(fx: *Fixture) !*const ev.Completion.CallbackFn {
    const cb = fx.pool.timer.c.callback.?;
    fx.pool.timer.c.callback = null;
    fireTimer(fx);
    var steps: usize = 0;
    while (true) : (steps += 1) {
        if (steps == max_steps) return error.NoProgress;
        try fx.loop.poll(.zero);
        if (fx.loop.nextDispatched()) |got| {
            try std.testing.expect(got == &fx.pool.timer.c);
            try std.testing.expect(fx.loop.nextDispatched() == null);
            return cb;
        }
    }
}

fn earliestOf(ws: []TestWaiter, also: zio.Timestamp) zio.Timestamp {
    var e = also;
    for (ws) |*w| if (w.w.deadline.value < e.value) {
        e = w.w.deadline;
    };
    return e;
}

test "f: the deadline timer is re-added from its own callback, fire after fire" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    _ = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{1}); // waits to read; the server never answers
    var ws: [3]TestWaiter = .{ .{ .pool = &fx.pool }, .{ .pool = &fx.pool }, .{ .pool = &fx.pool } };
    for (&ws) |*w| w.submit();
    const s = slot0(&fx);
    try std.testing.expectEqual(.connecting, s.state);
    const cb = fx.pool.timer.c.callback.?;
    try expectArmedFor(&fx, cb, earliestOf(&ws, s.connect_deadline));

    // A fire with nothing due re-adds the timer for the same deadline.
    const due_at = fx.pool.timer_due.?;
    fireTimer(&fx);
    try fx.until(&fx, struct {
        fn f(x: *Fixture) bool {
            return timerRegistered(x) and x.pool.timer.timeout.deadline.value != 0;
        }
    }.f);
    try expectArmedFor(&fx, cb, due_at);
    for (&ws) |*w| try std.testing.expectEqual(@as(usize, 0), w.n);

    // Each fire expires one waiter made due, and the callback re-adds the
    // timer for what still runs: the later waiters and the connect.
    for (&ws, 0..) |*w, i| {
        w.w.deadline = .zero;
        fireTimer(&fx);
        try fx.until(w, delivered);
        try std.testing.expectEqual(.err, w.got[0].kind);
        try std.testing.expectEqualSlices(u8, "57014", &w.got[0].sqlstate);
        for (ws[i + 1 ..]) |*o| try std.testing.expectEqual(@as(usize, 0), o.n);
        try expectArmedFor(&fx, cb, earliestOf(ws[i + 1 ..], s.connect_deadline));
    }

    // The connect's deadline is the last: once it expires nothing runs, and
    // the callback adds no timer.
    s.connect_deadline = .zero;
    fireTimer(&fx);
    try fx.until(&fx, Fixture.allDisconnected);
    try std.testing.expect(fx.pool.timer_due == null);
    try std.testing.expectEqual(.dead, fx.pool.timer.c.loadState().phase);
    try std.testing.expectEqual(@as(usize, 1), fake.count.get(.finish));
    try fx.deinit();
}

test "f: a shutdown while the timer's callback is on its way never re-arms the timer" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    var a: TestWaiter = .{ .pool = &fx.pool };
    _ = try sentAndBusy(&fx, &a, query());
    const cb = try holdTimer(&fx);
    // The pool cannot take the timer back from the loop now.
    try std.testing.expect(!fx.loop.clearTimer(&fx.pool.timer));
    fx.pool.stop();
    fx.pool.abort();
    try std.testing.expectEqual(@as(usize, 1), a.n);
    try std.testing.expectEqual(.abandoned, a.got[0].kind);
    try std.testing.expectEqualSlices(u8, "57014", &a.got[0].sqlstate);
    // Left to the callback, which finds nothing running and adds no timer.
    try std.testing.expect(fx.pool.timer_due != null);
    const mark = fake.calls;
    cb(&fx.loop, &fx.pool.timer.c);
    try expectKinds(mark, &[_]Kind{});
    try std.testing.expect(fx.pool.timer_due == null);
    try std.testing.expectEqual(.dead, fx.pool.timer.c.loadState().phase);
    try std.testing.expectEqual(@as(usize, 1), a.n);
    try fx.until(&fx, Fixture.allDisconnected);
    try fx.deinit();
}

test "f: an update while the timer's callback is on its way is left to that callback, which re-adds the timer" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    _ = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{1}); // waits to read; the server never answers
    var ws: [2]TestWaiter = .{ .{ .pool = &fx.pool }, .{ .pool = &fx.pool } };
    ws[0].submit();
    const cb = try holdTimer(&fx);
    const held = fx.pool.timer_due.?;
    // A query with an earlier deadline: the pool cannot take the timer back,
    // so the timer stays with its callback.
    in_submit = true;
    fx.pool.submit(&ws[1].w, queryMs(far / 2));
    in_submit = false;
    try std.testing.expect(ws[1].w.deadline.value < held.value);
    try std.testing.expect(fx.pool.timer_due.?.value == held.value);
    try std.testing.expect(!timerRegistered(&fx));
    // The callback finds nothing due and re-adds the timer for the earliest
    // deadline, the new query's.
    cb(&fx.loop, &fx.pool.timer.c);
    try std.testing.expectEqual(@as(usize, 0), ws[0].n + ws[1].n);
    try expectArmedFor(&fx, cb, ws[1].w.deadline);
    try std.testing.expectEqual(ws[1].w.deadline.value, earliestOf(&ws, slot0(&fx).connect_deadline).value);

    // A shutdown then takes the re-added timer back: it never fires.
    fx.pool.stop();
    fx.pool.abort();
    for (&ws) |*w| {
        try std.testing.expectEqual(@as(usize, 1), w.n);
        try std.testing.expectEqualSlices(u8, "57014", &w.got[0].sqlstate);
    }
    try std.testing.expect(fx.pool.timer_due == null);
    try std.testing.expectEqual(.new, fx.pool.timer.c.loadState().phase);
    try fx.until(&fx, Fixture.allDisconnected);
    try fx.idle();
    try std.testing.expectEqual(.new, fx.pool.timer.c.loadState().phase);
    try fx.deinit();
}

test "f: a budget of 0 or above the ceiling is refused with 22023, unsent" {
    var fx: Fixture = .{};
    try fx.initBudgets(1, .{ .query_ms = 100, .query_max_ms = 200, .connect_ms = far });
    var w: TestWaiter = .{ .pool = &fx.pool };
    for ([_]u32{ 0, 201 }, 1..) |ms, n| {
        in_submit = true;
        fx.pool.submit(&w.w, queryMs(ms));
        in_submit = false;
        try std.testing.expectEqual(n, w.n);
        try std.testing.expectEqual(.err, w.got[n - 1].kind);
        try std.testing.expectEqualSlices(u8, "22023", &w.got[n - 1].sqlstate);
    }
    try std.testing.expectEqual(@as(usize, 2), w.during_submit);
    try std.testing.expectEqual(@as(usize, 0), fake.count.get(.start));
    try fx.deinit();
}

test "f: the shutdown drain's end answers every query, closes every session and refuses later queries unsent" {
    var fx: Fixture = .{};
    try fx.initBudgets(2, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    var a: TestWaiter = .{ .pool = &fx.pool };
    const peer = try sentAndBusy(&fx, &a, query());
    // b waits for a second session, whose connect waits on the server.
    _ = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{1});
    var b: TestWaiter = .{ .pool = &fx.pool };
    b.submit();
    try std.testing.expectEqual(.connecting, fx.pool.slots[1].state);
    fx.pool.stop();
    try std.testing.expectEqual(@as(usize, 0), a.n + b.n);
    // a's handler asks again from its delivery (TestWaiter.deliver panics
    // on a delivery nested in another).
    a.again = 1;
    fx.pool.abort();
    // All are answered within abort: a abandoned (it was sent), b unsent,
    // and a's second query unsent, in the same run of dispatch.
    try std.testing.expectEqual(.abandoned, a.got[0].kind);
    try std.testing.expectEqualSlices(u8, "57014", &a.got[0].sqlstate);
    try std.testing.expectEqual(@as(usize, 2), a.n);
    try std.testing.expectEqual(.err, a.got[1].kind);
    try std.testing.expectEqualSlices(u8, "57014", &a.got[1].sqlstate);
    try std.testing.expectEqual(.err, b.got[0].kind);
    try std.testing.expectEqualSlices(u8, "57014", &b.got[0].sqlstate);
    try fx.until(&fx, Fixture.allDisconnected);
    try std.testing.expectEqual(@as(usize, 2), fake.count.get(.finish));
    try std.testing.expectError(error.Write, poke(peer));
    // A later query is answered at once, unsent, and starts no connect.
    const starts = fake.count.get(.start);
    in_submit = true;
    fx.pool.submit(&a.w, query());
    in_submit = false;
    try std.testing.expectEqual(@as(usize, 3), a.n);
    try std.testing.expectEqual(.err, a.got[2].kind);
    try std.testing.expectEqualSlices(u8, "57014", &a.got[2].sqlstate);
    try std.testing.expectEqual(starts, fake.count.get(.start));
    try std.testing.expect(fx.pool.timer_due == null);
    try fx.deinit();
}

// ---- (g) a lost connection: sent or not ----

test "g: a connection found failed before the query reached libpq fails it with error 08006" {
    var fx: Fixture = .{};
    try fx.init(1);
    _ = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{3});
    fake.send.push(&.{3});
    var w: TestWaiter = .{ .pool = &fx.pool };
    w.submit();
    try std.testing.expectEqual(.err, w.got[0].kind);
    try std.testing.expectEqualSlices(u8, "08006", &w.got[0].sqlstate);
    try fx.until(&fx, Fixture.allDisconnected);
    try fx.deinit();
}

test "g: a connection lost after the query was handed to libpq abandons it with 08006" {
    // send fails after handing it over (2), a flush fails, a read fails.
    for (0..3) |how| {
        var fx: Fixture = .{};
        try fx.init(1);
        const peer = try fx.pair();
        fake.start.push(&.{1});
        fake.connect_poll.push(&.{3});
        var w: TestWaiter = .{ .pool = &fx.pool };
        switch (how) {
            0 => fake.send.push(&.{2}),
            1 => {
                fake.send.push(&.{0});
                fake.flush.push(&.{-1});
            },
            else => {
                fake.send.push(&.{0});
                fake.flush.push(&.{0});
                fake.consume.push(&.{0});
            },
        }
        w.submit();
        if (how == 2) {
            try poke(peer);
            try fx.until(&w, delivered);
        }
        try std.testing.expectEqual(@as(usize, 1), w.n);
        try std.testing.expectEqual(.abandoned, w.got[0].kind);
        try std.testing.expectEqualSlices(u8, "08006", &w.got[0].sqlstate);
        try fx.until(&fx, Fixture.allDisconnected);
        try fx.deinit();
    }
}

// ---- (h) a failed connect while sessions are busy ----

test "h: a connect that fails while a session is busy keeps the queue, starting no connect until that session's answer, which serves it" {
    var fx: Fixture = .{};
    try fx.initBudgets(2, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    var a: TestWaiter = .{ .pool = &fx.pool };
    const peer = try sentAndBusy(&fx, &a, query());
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{0}); // the second connect fails at once
    var b: TestWaiter = .{ .pool = &fx.pool };
    var d: TestWaiter = .{ .pool = &fx.pool };
    b.submit();
    try std.testing.expectEqual(@as(usize, 0), b.n);
    try std.testing.expect(fx.pool.connect_failed);
    try std.testing.expectEqual(.disconnected, fx.pool.slots[1].state);
    // A later query waits too, and starts no connect.
    d.submit();
    try std.testing.expectEqual(@as(usize, 2), fake.count.get(.start));
    // a's answer clears the failure: its session runs b, and with d still
    // waiting a connect starts again; it fails too while b runs, so d
    // waits for that session as well.
    fake.consume.push(&.{ 1, 1, 1 });
    fake.collect.push(&.{ 1, 1, 1 });
    fake.send.push(&.{ 0, 0 });
    fake.flush.push(&.{ 0, 0 });
    fake.start.push(&.{0});
    try poke(peer);
    try fx.until(&a, delivered);
    try std.testing.expectEqual(@as(usize, 3), fake.count.get(.start));
    try std.testing.expect(fx.pool.connect_failed);
    try std.testing.expectEqual(@as(usize, 0), d.n);
    try poke(peer);
    try fx.until(&b, delivered);
    try poke(peer);
    try fx.until(&d, delivered);
    for ([_]*TestWaiter{ &a, &b, &d }) |x| {
        try std.testing.expectEqual(@as(usize, 1), x.n);
        try std.testing.expectEqual(.rows, x.got[0].kind);
    }
    try fx.deinit();
}

test "h: a connect's deadline passing while a session is busy follows the same rule" {
    var fx: Fixture = .{};
    try fx.initBudgets(2, .{ .query_ms = far, .query_max_ms = far, .connect_ms = 10 });
    var a: TestWaiter = .{ .pool = &fx.pool };
    const peer = try sentAndBusy(&fx, &a, query());
    _ = try fx.pair();
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{1}); // the second connect waits on a silent server
    var b: TestWaiter = .{ .pool = &fx.pool };
    b.submit();
    try std.testing.expectEqual(.connecting, fx.pool.slots[1].state);
    try fx.untilTimer(&fx, slotIs(1, .disconnected));
    try std.testing.expect(fx.pool.connect_failed);
    try std.testing.expectEqual(@as(usize, 0), b.n);
    fake.consume.push(&.{ 1, 1 });
    fake.collect.push(&.{ 1, 1 });
    fake.send.push(&.{0});
    fake.flush.push(&.{0});
    try poke(peer);
    try fx.until(&a, delivered);
    try poke(peer);
    try fx.until(&b, delivered);
    try std.testing.expectEqual(.rows, b.got[0].kind);
    try fx.deinit();
}

test "h: the queue kept for a busy session fails once with 08006 when that session ends without an answer" {
    var fx: Fixture = .{};
    try fx.initBudgets(2, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    var a: TestWaiter = .{ .pool = &fx.pool };
    const peer = try sentAndBusy(&fx, &a, query());
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{0});
    var b: TestWaiter = .{ .pool = &fx.pool };
    var d: TestWaiter = .{ .pool = &fx.pool };
    b.submit();
    d.submit();
    try std.testing.expectEqual(@as(usize, 0), b.n + d.n);
    // a's connection is lost mid-query: a is abandoned, the queue fails.
    fake.consume.push(&.{0});
    try poke(peer);
    try fx.until(&d, delivered);
    try std.testing.expectEqual(.abandoned, a.got[0].kind);
    try std.testing.expectEqualSlices(u8, "08006", &a.got[0].sqlstate);
    for ([_]*TestWaiter{ &b, &d }) |x| {
        try std.testing.expectEqual(@as(usize, 1), x.n);
        try std.testing.expectEqual(.err, x.got[0].kind);
        try std.testing.expectEqualSlices(u8, "08006", &x.got[0].sqlstate);
    }
    try std.testing.expect(!fx.pool.connect_failed);
    try std.testing.expect(fx.pool.head == null);
    try fx.until(&fx, Fixture.allDisconnected);
    try std.testing.expectEqual(@as(usize, 2), fake.count.get(.start));
    try fx.deinit();
}

test "h: a query kept for a busy session still ends at its own deadline" {
    var fx: Fixture = .{};
    try fx.initBudgets(2, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    var a: TestWaiter = .{ .pool = &fx.pool };
    const peer = try sentAndBusy(&fx, &a, query());
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{0});
    var b: TestWaiter = .{ .pool = &fx.pool };
    fx.pool.submit(&b.w, queryMs(10));
    try std.testing.expect(fx.pool.connect_failed);
    try fx.untilTimer(&b, delivered);
    try std.testing.expectEqual(.err, b.got[0].kind);
    try std.testing.expectEqualSlices(u8, "57014", &b.got[0].sqlstate);
    try std.testing.expectEqual(.busy, slot0(&fx).state);
    fake.consume.push(&.{1});
    fake.collect.push(&.{1});
    try poke(peer);
    try fx.until(&a, delivered);
    try std.testing.expectEqual(.rows, a.got[0].kind);
    try fx.deinit();
}

test "h: the busy session's own expiry ends the wait: the queue kept for it fails once with 08006" {
    var fx: Fixture = .{};
    try fx.initBudgets(2, .{ .query_ms = far, .query_max_ms = far, .connect_ms = far });
    var a: TestWaiter = .{ .pool = &fx.pool };
    _ = try sentAndBusy(&fx, &a, queryMs(10));
    fake.start.push(&.{1});
    fake.connect_poll.push(&.{0});
    var b: TestWaiter = .{ .pool = &fx.pool };
    b.submit();
    try std.testing.expect(fx.pool.connect_failed);
    try fx.untilTimer(&b, delivered);
    try std.testing.expectEqual(.abandoned, a.got[0].kind);
    try std.testing.expectEqualSlices(u8, "57014", &a.got[0].sqlstate);
    try std.testing.expectEqual(.err, b.got[0].kind);
    try std.testing.expectEqualSlices(u8, "08006", &b.got[0].sqlstate);
    try std.testing.expect(!fx.pool.connect_failed);
    try fx.until(&fx, Fixture.allDisconnected);
    try fx.deinit();
}
