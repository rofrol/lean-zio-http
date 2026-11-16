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
    kind: enum { query, rows, err },
    sqlstate: [5]u8 = "     ".*,
};

const Session = struct {
    id: u32,
    /// "libpq's socket": the slot end of the test's socketpair.
    fd: c.fd_t,
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
    /// 0 more input, 1 rows, -1 the session ends with 0A000 (COPY).
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

export fn ekk_pg_lost(_: ?*anyopaque) Lean {
    return newObj(.{ .kind = .err, .sqlstate = "08006".* });
}

export fn ekk_pg_start(_: [*:0]const u8) ?*anyopaque {
    fake.note(.start, fake.sessions + 1);
    if (fake.start.next("ekk_pg_start") == 0) return null;
    fake.sessions += 1;
    const s = std.testing.allocator.create(Session) catch @panic("out of memory");
    s.* = .{ .id = fake.sessions, .fd = fake.next_fd };
    fake.next_fd = -1;
    return s;
}

export fn ekk_pg_connect_poll(p: *anyopaque) c_int {
    fake.note(.connect_poll, sessionOf(p).id);
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
    fake.note(.collect, sessionOf(p).id);
    const rc = fake.collect.next("ekk_pg_collect");
    if (acc.* != null) @panic("collect: an accumulated value the fake never made");
    switch (rc) {
        0 => {},
        1 => acc.* = newObj(.{ .kind = .rows }),
        else => acc.* = newObj(.{ .kind = .err, .sqlstate = "0A000".* }),
    }
    return rc;
}

export fn ekk_query_drop(q: Lean) void {
    _ = freeObj(q);
}

fn query() Lean {
    return newObj(.{ .kind = .query });
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
        fake = .{};
        depth = 0;
        max_depth = 0;
        try self.loop.init(.{});
        self.pool.init(&self.loop, "fake", self.slots[0..nslots], false);
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

test "d: zero slots: a chain of failures stays iterative and runs inside one submit" {
    var fx: Fixture = .{};
    try fx.init(0);
    var w: TestWaiter = .{ .pool = &fx.pool, .again = chain - 1 };
    w.submit();
    try std.testing.expectEqual(@as(usize, chain), w.n);
    try std.testing.expectEqualSlices(u8, "08006", &w.got[31].sqlstate);
    try std.testing.expectEqual(@as(u32, 1), max_depth);
    // Evidence for the scheduling question: the whole chain ran before
    // `submit` returned, so the loop got no turn in between.
    try std.testing.expectEqual(@as(usize, chain), w.during_submit);
    try fx.deinit();
}

test "d: the database down: synchronous connect failures stay iterative and run inside one submit" {
    // Both ways a connect fails at once: PQconnectStart fails (no session),
    // or the first PQconnectPoll does.
    for ([_]c_int{ 0, 1 }) |start| {
        var fx: Fixture = .{};
        try fx.init(2);
        fake.start.repeat = start;
        fake.connect_poll.repeat = 0;
        var w: TestWaiter = .{ .pool = &fx.pool, .again = chain - 1 };
        w.submit();
        try std.testing.expectEqual(@as(usize, chain), w.n);
        try std.testing.expectEqualSlices(u8, "08006", &w.got[31].sqlstate);
        try std.testing.expectEqual(@as(u32, 1), max_depth);
        try std.testing.expectEqual(@as(usize, chain), w.during_submit);
        try std.testing.expectEqual(@as(usize, chain), fake.count.get(.start));
        try std.testing.expectEqual(@as(usize, if (start == 1) chain else 0), fake.count.get(.finish));
        fake.start.repeat = null;
        fake.connect_poll.repeat = null;
        fx.pool.stop();
        fx.loop.deinit();
        try std.testing.expectEqual(@as(i64, 0), fake.live);
    }
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
