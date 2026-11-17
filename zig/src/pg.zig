// The PostgreSQL pool of one loop: at most `size` libpq connections, owned
// by the loop's thread and driven by its zio.ev in libpq's non-blocking mode,
// so a query never blocks the loop. Queries and results are Lean values
// (Server/Query.lean); pg.c makes the libpq calls and builds the
// results. The pool knows nothing of HTTP: a query comes with a `Waiter`
// (embedded in the connection that asked) and its result goes to the
// waiter's `deliver` (README, "PostgreSQL").
//
// Rules the code below keeps:
// - Every query gets exactly one result: rows, PostgreSQL's error, or a
//   pool error (`08006` when the connection was lost or could not be made,
//   `54000` for a query that cannot be sent). A query is never retried: once
//   it may have reached the server, losing the connection fails it.
// - Waiters wait in FIFO order when no slot is free (pool exhaustion); each
//   waiter has at most one query (Conn.step_query), so the queue is bounded
//   by the loop's connections.
// - Connections open on demand, for the query that needs one; there are no
//   timers, retries or backoff. A failed connect fails that query.
// - zio's socket registry keeps a registration per descriptor until a
//   `NetClose` removes it (and asserts nothing is parked on it), while libpq
//   closes and may replace its own socket (PQfinish, PQconnectPoll). So the
//   pool never registers libpq's descriptor: it polls a duplicate it owns
//   and removes it with `NetClose` once no poll on it is outstanding; during
//   the connect a fresh duplicate is taken for every PQconnectPoll step.
const std = @import("std");
const zio = @import("zio");
const ev = zio.ev;
const os = zio.os;

/// pg.c's `ekk_pg`: a libpq connection and the statements prepared on it.
const Session = opaque {};
const Lean = ?*anyopaque; // a Lean object: Server.Query or Server.Query.Result

extern fn ekk_pg_error(sqlstate: [*:0]const u8, message: [*:0]const u8) Lean;
extern fn ekk_pg_lost(c: ?*Session) Lean;
extern fn ekk_pg_start(conninfo: [*:0]const u8) ?*Session;
extern fn ekk_pg_connect_poll(c: *Session) c_int;
extern fn ekk_pg_socket(c: *Session) c_int;
extern fn ekk_pg_finish(c: *Session) void;
extern fn ekk_dup(fd: c_int) c_int;
extern fn ekk_pg_send(c: *Session, q: Lean, err: *Lean) c_int;
extern fn ekk_pg_flush(c: *Session) c_int;
extern fn ekk_pg_consume(c: *Session) c_int;
extern fn ekk_pg_collect(c: *Session, acc: *Lean) c_int;
extern fn ekk_query_drop(q: Lean) void;

/// What waits for a query: embedded in the asking connection. `deliver`
/// receives the result (owned) and may submit the waiter's next query at once.
pub const Waiter = struct {
    query: Lean = null,
    next: ?*Waiter = null,
    deliver: *const fn (*Waiter, Lean) void,
};

/// A slot's lifecycle. `connecting` and `busy` run `waiter`'s query;
/// `closing` waits for its polls to be retired and its duplicate to be closed
/// before PQfinish.
const SlotState = enum { disconnected, connecting, idle, busy, closing };

pub const Slot = struct {
    pool: *Pool,
    state: SlotState = .disconnected,
    pg: ?*Session = null,
    /// The loop's duplicate of libpq's socket, or -1.
    fd: c_int = -1,
    waiter: ?*Waiter = null,
    /// busy: the query is sent and its results are being collected.
    acc: Lean = null,
    /// busy: libpq has output left to send.
    flushing: bool = false,
    /// Readability: a receive of one byte with MSG_PEEK, which leaves the
    /// bytes to libpq. zio tries a receive first and parks on its kqueue or
    /// epoll registration only when nothing is there; NetPoll would probe
    /// with poll(2) instead, which costs more than the receive.
    rpoll: ev.NetRecv = undefined,
    peek: [1]u8 = undefined,
    peek_iov: [1]os.iovec = undefined,
    wpoll: ev.NetPoll = undefined,
    rarmed: bool = false,
    warmed: bool = false,
    closer: ev.NetClose = undefined,
    /// The duplicate's `NetClose` is in flight.
    unregistering: bool = false,

    fn loop(self: *Slot) *ev.Loop {
        return self.pool.loop;
    }

    fn arm(self: *Slot, comptime dir: ev.NetPoll.Event) void {
        if (dir == .recv) {
            if (self.rarmed) return;
            self.rarmed = true;
            self.rpoll = ev.NetRecv.init(self.fd, .fromSlice(&self.peek, &self.peek_iov), .{ .peek = true });
            self.rpoll.c.callback = recvReady;
            self.rpoll.c.userdata = self;
            self.loop().add(&self.rpoll.c);
        } else {
            if (self.warmed) return;
            self.warmed = true;
            self.wpoll = ev.NetPoll.init(self.fd, .send);
            self.wpoll.c.callback = sendReady;
            self.wpoll.c.userdata = self;
            self.loop().add(&self.wpoll.c);
        }
    }

    /// Duplicates libpq's current socket for the loop to poll.
    fn takeSocket(self: *Slot) bool {
        const s = ekk_pg_socket(self.pg.?);
        if (s < 0) return false;
        self.fd = ekk_dup(s);
        return self.fd >= 0;
    }

    /// Removes the duplicate from zio's registry and closes it, then goes on
    /// in `closed`. Its polls must be retired.
    fn unregister(self: *Slot) void {
        std.debug.assert(!self.rarmed and !self.warmed and self.fd >= 0);
        self.unregistering = true;
        self.closer = ev.NetClose.init(self.fd);
        self.closer.c.callback = closed;
        self.closer.c.userdata = self;
        self.loop().add(&self.closer.c);
    }

    fn closed(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Slot = @ptrCast(@alignCast(c.userdata.?));
        self.unregistering = false;
        self.fd = -1;
        switch (self.state) {
            .connecting => self.connectStep(),
            .closing => self.finished(),
            else => @panic("a duplicate closed in an unexpected state"),
        }
    }

    // ---- connecting ----

    /// Opens a connection for `w`'s query.
    fn connect(self: *Slot, w: *Waiter) void {
        std.debug.assert(self.state == .disconnected);
        self.waiter = w;
        self.state = .connecting;
        self.pg = ekk_pg_start(self.pool.conninfo);
        self.connectStep();
    }

    /// One PQconnectPoll step, with no duplicate registered.
    fn connectStep(self: *Slot) void {
        const pg = self.pg orelse return self.connectFailed();
        switch (ekk_pg_connect_poll(pg)) {
            1, 2 => |dir| {
                if (!self.takeSocket()) return self.connectFailed();
                if (dir == 1) self.arm(.recv) else self.arm(.send);
            },
            3 => {
                if (!self.takeSocket()) return self.connectFailed();
                self.state = .busy;
                self.arm(.recv); // armed for the connection's whole life
                self.send();
            },
            else => self.connectFailed(),
        }
    }

    fn connectFailed(self: *Slot) void {
        const w = self.waiter.?;
        const err = ekk_pg_lost(self.pg);
        if (self.pg) |pg| ekk_pg_finish(pg);
        self.pg = null;
        self.waiter = null;
        self.state = .disconnected;
        ekk_query_drop(w.query);
        w.query = null;
        w.deliver(w, err);
        self.pool.next(self);
    }

    // ---- connected ----

    /// Sends the waiter's query on a connected slot.
    fn send(self: *Slot) void {
        const w = self.waiter.?;
        const q = w.query;
        w.query = null;
        var err: Lean = null;
        switch (ekk_pg_send(self.pg.?, q, &err)) {
            0 => self.flush(),
            1 => {
                // Not sent; the connection is unchanged.
                self.waiter = null;
                self.state = .idle;
                w.deliver(w, err);
                self.pool.next(self);
            },
            else => self.lost(),
        }
    }

    fn flush(self: *Slot) void {
        switch (ekk_pg_flush(self.pg.?)) {
            0 => self.flushing = false,
            1 => {
                self.flushing = true;
                self.arm(.send);
            },
            else => self.lost(),
        }
    }

    fn recvReady(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Slot = @ptrCast(@alignCast(c.userdata.?));
        self.rarmed = false;
        const ok = if (self.rpoll.getResult()) |_| true else |_| false;
        switch (self.state) {
            .connecting => {
                if (!ok) return self.connectFailedAfterPoll();
                self.unregister();
            },
            .closing => self.retire(),
            .idle => {
                // Nothing is asked of an idle connection: this is a notice, a
                // parameter status, or the server closing it.
                if (!ok or ekk_pg_consume(self.pg.?) == 0) return self.teardown();
                self.arm(.recv);
            },
            .busy => {
                if (!ok or ekk_pg_consume(self.pg.?) == 0) return self.lost();
                if (self.flushing) {
                    self.flush();
                    if (self.state != .busy) return;
                }
                self.arm(.recv);
                self.collect();
            },
            .disconnected => @panic("a poll completed on a disconnected slot"),
        }
    }

    fn sendReady(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Slot = @ptrCast(@alignCast(c.userdata.?));
        self.warmed = false;
        const ok = if (self.wpoll.getResult()) |_| true else |_| false;
        switch (self.state) {
            .connecting => {
                if (!ok) return self.connectFailedAfterPoll();
                self.unregister();
            },
            .closing => self.retire(),
            .busy => {
                if (!ok) return self.lost();
                if (self.flushing) self.flush();
            },
            // Armed for an earlier query whose output a receive callback
            // finished flushing; nothing waits for it now.
            .idle => {},
            .disconnected => @panic("a send poll completed on a disconnected slot"),
        }
    }

    /// A connect step's poll failed: its duplicate is still registered.
    fn connectFailedAfterPoll(self: *Slot) void {
        self.state = .closing;
        self.retire();
    }

    /// Collects the results that have arrived; delivers once complete.
    fn collect(self: *Slot) void {
        const rc = ekk_pg_collect(self.pg.?, &self.acc);
        if (rc == 0) return;
        const w = self.waiter.?;
        const result = self.acc;
        self.acc = null;
        self.waiter = null;
        if (rc < 0) {
            // COPY, a transaction left open, a lost connection or too many
            // stale statements (pg.c): the session serves no other query.
            self.teardown();
        } else {
            self.state = .idle;
        }
        w.deliver(w, result);
        if (self.state == .idle) self.pool.next(self);
    }

    /// The connection failed while busy: the query fails with `08006`.
    fn lost(self: *Slot) void {
        const w = self.waiter.?;
        const err = ekk_pg_lost(self.pg);
        if (self.acc) |a| ekk_query_drop(a);
        self.acc = null;
        self.waiter = null;
        self.teardown();
        w.deliver(w, err);
    }

    /// Ends the connection: retires its polls, unregisters the duplicate,
    /// then PQfinish (`finished`).
    fn teardown(self: *Slot) void {
        std.debug.assert(self.waiter == null);
        self.state = .closing;
        self.flushing = false;
        if (self.rarmed) self.loop().cancel(&self.rpoll.c);
        if (self.warmed) self.loop().cancel(&self.wpoll.c);
        self.retire();
    }

    /// In `closing`: once no poll is outstanding, unregisters the duplicate
    /// (or finishes when there is none).
    fn retire(self: *Slot) void {
        if (self.rarmed or self.warmed or self.unregistering) return;
        if (self.fd >= 0) return self.unregister();
        self.finished();
    }

    fn finished(self: *Slot) void {
        if (self.pg) |pg| {
            ekk_pg_finish(pg);
            if (self.pool.trace) std.debug.print("pg closed\n", .{});
        }
        self.pg = null;
        self.state = .disconnected;
        if (self.waiter) |w| {
            // A connect step ended in `closing` (connectFailedAfterPoll).
            self.waiter = null;
            ekk_query_drop(w.query);
            w.query = null;
            w.deliver(w, ekk_pg_error("08006", "the connection to the server failed"));
        }
        self.pool.next(self);
    }

    /// Runs `w`'s query on this idle slot. An idle slot's receive stays
    /// armed, so a connection the server closed while it was idle is ended
    /// when the loop handles its EOF. That is best effort: a request the
    /// loop handles first sends its query on the closed connection, which
    /// fails it with `08006` like any query on a connection that fails.
    fn run(self: *Slot, w: *Waiter) void {
        std.debug.assert(self.state == .idle);
        self.waiter = w;
        self.state = .busy;
        self.send();
    }
};

pub const Pool = struct {
    loop: *ev.Loop,
    conninfo: [*:0]const u8,
    slots: []Slot,
    head: ?*Waiter = null,
    tail: ?*Waiter = null,
    /// The loop is shutting down: idle connections close, and a slot that
    /// finds no waiter closes too.
    stopping: bool = false,
    /// `dispatch` is running further up the stack: a nested call returns at
    /// once and the running one picks up what changed, so a run of
    /// synchronous connect failures (the database down) is a loop, not a
    /// recursion as deep as the queue.
    dispatching: bool = false,
    /// Prints `pg closed` when a slot has ended its session (tests).
    trace: bool,

    pub fn init(self: *Pool, loop: *ev.Loop, conninfo: [*:0]const u8, slots: []Slot, trace: bool) void {
        self.* = .{ .loop = loop, .conninfo = conninfo, .slots = slots, .trace = trace };
        for (slots) |*s| s.* = .{ .pool = self };
    }

    /// Runs query `q` (owned) for `w`; the result reaches `w.deliver`, at
    /// once when there is no slot to run it at all.
    pub fn submit(self: *Pool, w: *Waiter, q: Lean) void {
        std.debug.assert(w.query == null and w.next == null);
        w.query = q;
        self.enqueue(w);
        self.dispatch();
    }

    fn enqueue(self: *Pool, w: *Waiter) void {
        if (self.tail) |t| t.next = w else self.head = w;
        self.tail = w;
    }

    fn dequeue(self: *Pool) ?*Waiter {
        const w = self.head orelse return null;
        self.head = w.next;
        if (self.head == null) self.tail = null;
        w.next = null;
        return w;
    }

    /// Gives waiting queries to slots: idle connections first, then slots
    /// that can open one.
    fn dispatch(self: *Pool) void {
        if (self.dispatching) return;
        self.dispatching = true;
        defer self.dispatching = false;
        while (self.head != null) {
            if (self.slots.len == 0) {
                // No database configured (--pg): fail each query. Through
                // this loop, a handler that asks again on the error does not
                // recurse.
                const w = self.dequeue().?;
                ekk_query_drop(w.query);
                w.query = null;
                w.deliver(w, ekk_pg_error("08006", "no database is configured (--pg)"));
                continue;
            }
            const slot = self.free() orelse break;
            const w = self.dequeue().?;
            if (slot.state == .idle) slot.run(w) else slot.connect(w);
        }
        if (self.stopping and self.head == null) {
            for (self.slots) |*s| if (s.state == .idle) s.teardown();
        }
    }

    fn free(self: *Pool) ?*Slot {
        for (self.slots) |*s| if (s.state == .idle) return s;
        for (self.slots) |*s| if (s.state == .disconnected) return s;
        return null;
    }

    /// A slot became idle or disconnected.
    fn next(self: *Pool, _: *Slot) void {
        self.dispatch();
    }

    /// The loop's shutdown: queries in flight and waiting still run; idle
    /// connections close now, the others once no query waits.
    pub fn stop(self: *Pool) void {
        self.stopping = true;
        self.dispatch();
    }
};
