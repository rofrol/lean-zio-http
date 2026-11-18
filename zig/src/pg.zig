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
//   pool error (`08006` when the connection could not be made or was lost
//   before the query was handed to libpq, `54000` for a query that cannot
//   be sent, `22023` for a completion budget outside 1 to the ceiling,
//   `57014` for a query whose deadline passed before it was sent), or the
//   query abandoned (`Result.abandoned`: `08006` when the connection was
//   lost after the query was handed to libpq, `57014` when its deadline
//   passed after that, unless its answer was already known and only the
//   Close of its forgotten statement was pending (`Slot.answered`),
//   `54000` when its result crossed
//   Query.maxResultBytes; each closes its session, so its outcome is
//   unknown). A query is never retried: once it may have reached the
//   server, losing the connection or closing its session fails it.
// - Deadlines (README, "PostgreSQL"): each query has a completion deadline
//   from its submission (queueing included) and the connect in flight one
//   from its start; all are external database budgets. One timer per pool
//   is armed for the earliest of them (`rearm`); its callback expires what
//   is due by the clock at that moment and re-arms. An expiry is
//   judged against the pool's current state (a waiter still queued, a slot
//   still busy with that waiter, the slot still connecting), so an expiry
//   that comes after the completion it raced finds nothing due and changes
//   nothing; a completion that the loop runs before a due expiry wins, as
//   for the connections' own deadlines. An expired busy session is
//   disposed of (PQfinish, no PQcancel) and never serves another query.
// - Waiters wait in FIFO order when no connection is idle (pool exhaustion,
//   or a connect in flight); each waiter has at most one query
//   (Conn.step_query), so the queue is bounded by the loop's connections.
// - Connections open on demand, when a query waits and no connection is
//   idle, and at most one connect per pool is in flight (`Pool.attempt`): a
//   connect is not tied to a query. When it succeeds, the new idle
//   connection serves the queue like any other. When it fails (or reaches
//   its deadline) with no connection busy, every query waiting at that
//   moment fails once with `08006`, and a query submitted later (also from
//   those deliveries) may start the next connect. When it fails while
//   connections are busy, the queue waits for them instead, each query to
//   its own deadline, and no connect starts (`Pool.connect_failed`) until
//   one of them gets a complete answer from the database; when the last
//   busy one ends without such an answer, the queue fails once with
//   `08006`. A busy connection is a candidate, not proof of health. A connect
//   ends at its deadline at the latest; there are no retries or backoff:
//   this bounds concurrent connects per loop, not the rate of connects while
//   the database stays down.
// - A chain of completions that the pool makes synchronously (a delivery
//   whose handler submits again and is answered at once: no slots, the
//   database down, a query that cannot be sent) runs inline for about
//   `chain_inline` completions per turn of the loop; the rest of it goes on
//   in a later turn of the loop (`yieldChain`), so a long chain does not
//   hold the loop's other ready work, and it may outlive the `submit` that
//   started it. Decided 2026-11-18, item rtkla3. Only the shutdown's
//   `abort` runs its chain to the end (`abort`).
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
extern fn ekk_pg_abandoned(sqlstate: [*:0]const u8, message: [*:0]const u8) Lean;
extern fn ekk_pg_lost(c: ?*Session) Lean;
extern fn ekk_pg_lost_sent(c: ?*Session) Lean;
extern fn ekk_query_timeout_ms(q: Lean, dflt: c_uint, ceiling: c_uint) c_uint;
extern fn ekk_pg_start(conninfo: [*:0]const u8, options: [*:0]const u8) ?*Session;
extern fn ekk_pg_connect_poll(c: *Session) c_int;
extern fn ekk_pg_socket(c: *Session) c_int;
extern fn ekk_pg_finish(c: *Session) void;
extern fn ekk_dup(fd: c_int) c_int;
extern fn ekk_pg_send(c: *Session, q: Lean, err: *Lean) c_int;
extern fn ekk_pg_flush(c: *Session) c_int;
extern fn ekk_pg_consume(c: *Session) c_int;
extern fn ekk_pg_collect(c: *Session, acc: *Lean) c_int;
extern fn ekk_query_drop(q: Lean) void;
/// Whether the process's libpq is one the pool supports (pg.c: 17 or
/// later), and its version (PQlibVersion).
pub extern fn ekk_pg_libpq_supported() c_int;
pub extern fn ekk_pg_libpq_version() c_int;

/// What waits for a query: embedded in the asking connection. `deliver`
/// receives the result (owned) and may submit the waiter's next query at once.
pub const Waiter = struct {
    query: Lean = null,
    next: ?*Waiter = null,
    /// When the query's completion budget ends (`now`'s clock).
    deadline: zio.Timestamp = .zero,
    /// A result decided without a slot (an expiry in the queue, a budget
    /// refused), waiting in the pool's `ready` list for its delivery.
    result: Lean = null,
    deliver: *const fn (*Waiter, Lean) void,
};

/// The budgets of the pool's deadlines in milliseconds, each an external
/// database budget (README, "PostgreSQL", "Deadlines"; Server.Transport
/// options `--pg-query-ms`, `--pg-query-max-ms`, `--pg-connect-ms`).
pub const Budgets = struct {
    /// A query's completion budget when it names none (Query.timeoutMs).
    query_ms: u32 = 5000,
    /// The largest Query.timeoutMs a query may name.
    query_max_ms: u32 = 5000,
    /// A connect, from its start to a connection ready for queries.
    connect_ms: u32 = 5000,
};

/// The completions one run of `Pool.dispatch` delivers before it hands the
/// rest of a synchronous chain to the loop's next turn (`Pool.yieldChain`).
/// A count, not a time. 64: a handler that asks again on an error a few
/// times (a short chain) finishes inline, with no extra turn of the loop,
/// while a turn runs about 64 handler steps of a long chain before the
/// loop serves its other ready work (the bound is checked between steps,
/// and one step may deliver several results: a failed connect answers
/// every query waiting): the same bound serve.zig puts on the accepts of
/// one callback (`default_accept_batch`), for the same reason.
pub const chain_inline: u32 = 64;

fn after(ms: u32, from: zio.Timestamp) zio.Timestamp {
    return from.addDuration(zio.Duration.fromMilliseconds(ms));
}

/// The clock of the deadlines: the deadline timer's own (`ev.Timer.clock`,
/// `.awake`), read fresh, not the loop's cached time.
fn now() zio.Timestamp {
    return zio.Timestamp.now(.awake);
}

fn due(t: zio.Timestamp, at: zio.Timestamp) bool {
    return t.value <= at.value;
}

/// Ends the process when a callback runs on a loop other than `own`, the
/// loop that owns the state it is about to touch. Every callback of the
/// transport (here and in serve.zig) calls it first. A loop's state is
/// touched only by that loop's thread, which holds as long as no zio
/// LoopGroup joins the loops (serve.zig, the comment above
/// `for (loops) |*lp| lp.* = .{ .lfd = lfd };` in `ekk_serve`; serve_test.zig
/// checks that `startLoop` joins none). This is the runtime backstop behind
/// that test: grouped loops complete each other's parked socket ops on the
/// completing loop's thread, and zio passes that completing loop to the
/// callback. It relies on zio's callback dispatch at the pin (53ed3c377317):
/// `Completion.call(loop)` calls the callback with the loop whose state
/// completes it (src/ev/completion.zig:491-495, src/ev/loop.zig:310-362);
/// recheck at each update of zio. An explicit `@panic`, not
/// `std.debug.assert`, which ReleaseFast compiles out.
pub fn ownLoop(got: *const ev.Loop, own: *const ev.Loop) void {
    if (got != own) @panic("a callback ran on a loop other than the one that owns its state");
}

/// A slot's lifecycle. `connecting` is the pool's one connect in flight
/// (`Pool.attempt`), for no query in particular; `busy` runs `waiter`'s
/// query; `closing` waits for its polls to be retired and its duplicate to be
/// closed before PQfinish.
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
    /// busy: collect returned 2, so `acc` is the query's answer while the
    /// session closes the statement it forgot (pg.c); a connection lost
    /// or a deadline passed from here on ends the session but delivers that
    /// answer (`lost`, `expire`).
    answered: bool = false,
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
    /// connecting: when the connect's budget ends.
    connect_deadline: zio.Timestamp = .zero,
    /// The connect in flight ended by its deadline (its waiters' message).
    connect_expired: bool = false,

    fn loop(self: *Slot) *ev.Loop {
        return self.pool.loop;
    }

    /// `recvReady` and `sendReady` re-arm their own completion through here,
    /// and `closed` may re-add `closer` (through `connectStep`, `Pool.next`
    /// and a failed send's `teardown`). zio documents that a callback may
    /// reuse its completion's memory and `add` it again (pinned 53ed3c377317,
    /// src/ev/completion.zig:294-305, `Completion.callback`,
    /// https://github.com/lalinsky/zio/pull/929): "for a completion with
    /// neither `rearm` nor a group or queue owner the loop does not touch it
    /// after the callback returns". The pool sets no `rearm` and uses no zio
    /// `Group` or `CompletionQueue`.
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

    fn closed(lp: *ev.Loop, c: *ev.Completion) void {
        const self: *Slot = @ptrCast(@alignCast(c.userdata.?));
        ownLoop(lp, self.loop());
        self.unregistering = false;
        self.fd = -1;
        switch (self.state) {
            .connecting => self.connectStep(),
            .closing => self.finished(),
            else => @panic("a duplicate closed in an unexpected state"),
        }
    }

    // ---- connecting ----

    /// Opens a connection: the pool's attempt, for the queries waiting.
    fn connect(self: *Slot) void {
        std.debug.assert(self.state == .disconnected and self.pool.attempt == null);
        self.pool.attempt = self;
        self.state = .connecting;
        self.connect_deadline = after(self.pool.budgets.connect_ms, now());
        self.connect_expired = false;
        self.pg = ekk_pg_start(self.pool.conninfo, self.pool.options);
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
                self.state = .idle;
                self.pool.attempt = null;
                self.arm(.recv); // armed for the connection's whole life
                self.pool.next(self);
            },
            else => self.connectFailed(),
        }
    }

    /// The connect failed with no duplicate registered.
    fn connectFailed(self: *Slot) void {
        self.pool.connectFailedFor(self.pg, null);
        if (self.pg) |pg| ekk_pg_finish(pg);
        self.pg = null;
        self.state = .disconnected;
        self.pool.attempt = null;
        self.pool.next(self);
    }

    // ---- connected ----

    /// Sends the waiter's query on a connected slot.
    fn send(self: *Slot) void {
        const w = self.waiter.?;
        const q = w.query;
        w.query = null;
        self.answered = false;
        var err: Lean = null;
        switch (ekk_pg_send(self.pg.?, q, &err)) {
            0 => self.flush(),
            1 => {
                // Not sent; the connection is unchanged.
                self.waiter = null;
                self.state = .idle;
                self.pool.complete(w, err);
                self.pool.next(self);
            },
            3 => {
                // The connection had failed before the query was handed to
                // libpq: proven never sent.
                const lost_err = ekk_pg_lost(self.pg);
                self.waiter = null;
                self.teardown();
                self.pool.complete(w, lost_err);
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

    fn recvReady(lp: *ev.Loop, c: *ev.Completion) void {
        const self: *Slot = @ptrCast(@alignCast(c.userdata.?));
        ownLoop(lp, self.loop());
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

    fn sendReady(lp: *ev.Loop, c: *ev.Completion) void {
        const self: *Slot = @ptrCast(@alignCast(c.userdata.?));
        ownLoop(lp, self.loop());
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
        // Collect queued commands of its own (the Close of a forgotten
        // statement, pg.c): flush them, then wait for their results.
        if (rc == 2) {
            self.answered = true;
            return self.flush();
        }
        const w = self.waiter.?;
        const result = self.acc;
        self.acc = null;
        self.waiter = null;
        if (rc < 0) {
            // COPY, a transaction left open, a result over the bound, a lost
            // connection or a failed Close (pg.c): the session serves no
            // other query.
            self.teardown();
        } else {
            // A complete answer of the database's: connects may start again.
            self.pool.connect_failed = false;
            self.state = .idle;
        }
        self.pool.complete(w, result);
        if (self.state == .idle) self.pool.next(self);
    }

    /// The connection failed while busy, after the query was handed to
    /// libpq: it is abandoned with `08006` (it may have run), or answered
    /// with its own result once that is known (`answered`).
    fn lost(self: *Slot) void {
        const w = self.waiter.?;
        const err = if (self.answered) self.acc else blk: {
            if (self.acc) |a| ekk_query_drop(a);
            break :blk ekk_pg_lost_sent(self.pg);
        };
        self.acc = null;
        self.waiter = null;
        self.teardown();
        self.pool.complete(w, err);
    }

    /// The query's deadline passed while busy (or the shutdown drain ended):
    /// its session is disposed of (never reused, no PQcancel) and the query
    /// abandoned with `57014`, or answered with its own result when that is
    /// already known (`answered`: only the Close of its forgotten statement
    /// was pending, which an expiry must not turn into an unknown outcome;
    /// decided 2026-11-17, item ncvxfx); delivered from the pool's `ready`
    /// list.
    fn expire(self: *Slot, message: [*:0]const u8) void {
        const w = self.waiter.?;
        const r = if (self.answered) self.acc else blk: {
            if (self.acc) |a| ekk_query_drop(a);
            break :blk ekk_pg_abandoned("57014", message);
        };
        self.acc = null;
        self.waiter = null;
        self.teardown();
        self.pool.ready(w, r);
    }

    /// The connect's deadline passed: its session ends like a failed one,
    /// and `finished` fails the queries waiting with `08006`.
    fn connectExpire(self: *Slot) void {
        self.connect_expired = true;
        self.teardown();
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
        // A connect step that ended in `closing` (connectFailedAfterPoll):
        // its poll failed, so libpq has no message worth reporting.
        const failed = self.pool.attempt == self;
        if (failed) self.pool.connectFailedFor(null, if (self.connect_expired) "the connect's deadline passed (--pg-connect-ms)" else null);
        if (self.pg) |pg| {
            ekk_pg_finish(pg);
            if (self.pool.trace) std.debug.print("pg closed\n", .{});
        }
        self.pg = null;
        self.state = .disconnected;
        if (failed) self.pool.attempt = null;
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
    /// The startup `options` of every session (pg.c, ekk_pg_options):
    /// statement_timeout among them.
    options: [*:0]const u8,
    budgets: Budgets,
    slots: []Slot,
    head: ?*Waiter = null,
    tail: ?*Waiter = null,
    /// Waiters whose result is decided (`Waiter.result`), delivered by
    /// `dispatch` in order.
    ready_head: ?*Waiter = null,
    ready_tail: ?*Waiter = null,
    /// The deadline timer, armed for `timer_due`. While that is set the
    /// timer is the loop's (registered, or fired with its callback still to
    /// run) and the pool does not overwrite it (`rearm`); its callback
    /// unsets it first.
    timer: ev.Timer = undefined,
    timer_due: ?zio.Timestamp = null,
    /// The slot whose connect is in flight: at most one per pool. It stays
    /// set while that connect's failure is delivered, so a query submitted
    /// from a delivery waits for the next connect instead of joining it.
    attempt: ?*Slot = null,
    /// The loop is shutting down: idle connections close, and a slot that
    /// finds no waiter closes too.
    stopping: bool = false,
    /// The shutdown's drain ended (`abort`): every query is answered at
    /// once, unsent, and no connect starts.
    aborted: bool = false,
    /// `dispatch` is running further up the stack: a nested call returns at
    /// once and the running one picks up what changed, so a run of
    /// synchronous connect failures (the database down) is a loop, not a
    /// recursion as deep as the queue.
    dispatching: bool = false,
    /// A connect failed while sessions were busy (`connectFailedFor`): the
    /// queries waiting wait for those sessions, and no connect starts, until
    /// a busy session gets a complete answer from the database (`collect`)
    /// or none is busy any more (`dispatch` then fails the queue).
    connect_failed: bool = false,
    /// Completions delivered (`complete`) since the outermost run of
    /// `dispatch` began, or while a yielded chain waits, since `contCb`
    /// began; at `chain_inline` the run yields (`yieldChain`).
    delivered: u32 = 0,
    /// The turn that goes on with a chain `dispatch` yielded: in the loop,
    /// notified, while `cont_armed` (`contCb`). The queue and the ready
    /// list are the record of what is left; this only brings the turn.
    cont: ev.Async = undefined,
    cont_armed: bool = false,
    /// Prints `pg closed` when a slot has ended its session (tests).
    trace: bool,

    /// The pool must not move afterwards: its slots and `cont` point to it.
    pub fn init(self: *Pool, loop: *ev.Loop, conninfo: [*:0]const u8, options: [*:0]const u8, budgets: Budgets, slots: []Slot, trace: bool) void {
        self.* = .{ .loop = loop, .conninfo = conninfo, .options = options, .budgets = budgets, .slots = slots, .trace = trace };
        self.cont = ev.Async.init();
        self.cont.c.callback = contCb;
        self.cont.c.userdata = self;
        for (slots) |*s| s.* = .{ .pool = self };
    }

    /// Runs query `q` (owned) for `w`; the result reaches `w.deliver`, from
    /// this call when the pool answers it at once (no slot to run it at
    /// all, the database down), unless this call's chain of such answers is
    /// already `chain_inline` long: then from a later turn of the loop
    /// (`yieldChain`). Its completion deadline starts now.
    pub fn submit(self: *Pool, w: *Waiter, q: Lean) void {
        std.debug.assert(w.query == null and w.next == null and w.result == null);
        const ms = ekk_query_timeout_ms(q, self.budgets.query_ms, self.budgets.query_max_ms);
        if (self.aborted) {
            ekk_query_drop(q);
            self.ready(w, ekk_pg_error("57014", "the server's shutdown drain ended (--drain-ms); the query was not sent"));
        } else if (ms == 0) {
            ekk_query_drop(q);
            self.ready(w, ekk_pg_error("22023", "Query.timeoutMs must be at least 1 and at most the server's ceiling (--pg-query-max-ms)"));
        } else {
            w.deadline = after(ms, now());
            w.query = q;
            self.enqueue(w);
        }
        self.dispatch();
    }

    /// Queues `w` for the delivery of `r` (owned) by `dispatch`.
    fn ready(self: *Pool, w: *Waiter, r: Lean) void {
        std.debug.assert(w.next == null and w.result == null);
        w.result = r;
        if (self.ready_tail) |t| t.next = w else self.ready_head = w;
        self.ready_tail = w;
    }

    /// Delivers `r` (owned) to `w`, counted for `dispatch`'s bound on a
    /// synchronous chain. Every result reaches its waiter through here.
    fn complete(self: *Pool, w: *Waiter, r: Lean) void {
        self.delivered +|= 1;
        w.deliver(w, r);
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

    /// Delivers the results decided without a slot, gives waiting queries
    /// to idle connections, and when queries still wait starts a connect
    /// unless one is in flight; then re-arms the deadline timer. Once this
    /// run has delivered `chain_inline` results and work is left, the rest
    /// waits for a later turn of the loop (`yieldChain`); a shutdown's
    /// `abort` runs to the end instead.
    fn dispatch(self: *Pool) void {
        if (self.dispatching) return;
        self.dispatching = true;
        defer self.dispatching = false;
        // While a yielded chain waits for its turn (`cont_armed`), the count
        // goes on: a submit from another callback in the meantime queues
        // behind the chain instead of running a further `chain_inline` of it
        // ahead of the loop's other ready work; `contCb` starts the count
        // afresh.
        if (!self.cont_armed) self.delivered = 0;
        while (true) {
            // After `abort`, serve.zig's drain closes every connection, and
            // a connection whose query is still in the pool must not be
            // closed (`Conn.cut`): so an aborted pool never yields.
            if (self.delivered >= chain_inline and !self.aborted and
                (self.ready_head != null or self.head != null))
            {
                self.yieldChain();
                break;
            }
            if (self.ready_head) |w| {
                self.ready_head = w.next;
                if (self.ready_head == null) self.ready_tail = null;
                w.next = null;
                const r = w.result;
                w.result = null;
                self.complete(w, r);
                continue;
            }
            if (self.connect_failed and self.find(.busy) == null) {
                // The sessions the queue waited for are gone without an
                // answer that cleared the failed connect: it fails now.
                self.connect_failed = false;
                while (self.dequeue()) |w| {
                    ekk_query_drop(w.query);
                    w.query = null;
                    self.ready(w, ekk_pg_error("08006", "could not connect, and no session that was running remained to serve the query"));
                }
                continue;
            }
            if (self.head == null) break;
            if (self.slots.len == 0) {
                // No database configured (--pg): fail each query. Through
                // this loop, a handler that asks again on the error does not
                // recurse.
                const w = self.dequeue().?;
                ekk_query_drop(w.query);
                w.query = null;
                self.complete(w, ekk_pg_error("08006", "no database is configured (--pg)"));
                continue;
            }
            if (self.find(.idle)) |slot| {
                slot.run(self.dequeue().?);
                continue;
            }
            if (self.attempt != null or self.connect_failed) break;
            // A connect that ends at once (success or failure) changes the
            // queue or the slots, and the loop goes on from there.
            const slot = self.find(.disconnected) orelse break;
            slot.connect();
        }
        if (self.stopping and self.head == null) {
            for (self.slots) |*s| if (s.state == .idle) s.teardown();
        }
        self.rearm();
    }

    /// Puts the rest of a chain on the loop's runnable queue: `cont`, added
    /// and notified, completes at the loop's next check of its handles, and
    /// a completion queued while the loop runs callbacks waits for the next
    /// tick (pinned 53ed3c377317, src/ev/completion.zig `Async.Pending`;
    /// src/ev/loop.zig `processCompletions`: "Drain only what was queued at
    /// entry ... The rest runs next tick"), so the loop serves the other
    /// work that is ready before the chain goes on. An armed handle keeps
    /// `Loop.run` from returning (`Loop.done`), so the rest of the chain is
    /// always delivered. Re-adding `cont` from its own callback is what
    /// serve.zig's `LoopCtx.readyCb` does with `wake`, on the same
    /// documentation.
    fn yieldChain(self: *Pool) void {
        if (self.cont_armed) return;
        self.cont_armed = true;
        self.loop.add(&self.cont.c);
        self.cont.notify();
    }

    /// A later turn of the loop: the chain `dispatch` yielded goes on.
    fn contCb(lp: *ev.Loop, c: *ev.Completion) void {
        const self: *Pool = @ptrCast(@alignCast(c.userdata.?));
        ownLoop(lp, self.loop);
        self.cont_armed = false;
        self.delivered = 0;
        self.dispatch();
    }

    /// Arms the deadline timer for the earliest deadline still running: a
    /// queued query's, a busy slot's query's, the connect's.
    ///
    /// While `timer_due` is set the timer belongs to the loop: registered,
    /// or fired with its callback still to run. Only `arm` re-initializes
    /// it, and only with `timer_due` unset, so a timer the loop holds is
    /// never re-initialized. The pool takes it back only through
    /// `Loop.clearTimer`; when that returns false the timer's callback is on
    /// its way and the timer is left to it: the callback unsets `timer_due`
    /// first (zio no longer touches the completion then) and re-arms
    /// through here. The pool never cancels the timer. That is
    /// also why a shutdown never re-arms it: once `abort` has answered
    /// everything no deadline is running, so neither this nor a callback
    /// still on its way arms it again.
    fn rearm(self: *Pool) void {
        var next_due: ?zio.Timestamp = null;
        var it = self.head;
        while (it) |w| : (it = w.next) next_due = earliest(next_due, w.deadline);
        for (self.slots) |*s| switch (s.state) {
            .busy => next_due = earliest(next_due, s.waiter.?.deadline),
            .connecting => next_due = earliest(next_due, s.connect_deadline),
            else => {},
        };
        if (self.timer_due) |d| {
            if (next_due) |n| if (n.value == d.value) return;
            if (!self.loop.clearTimer(&self.timer)) return;
            self.timer_due = null;
        }
        if (next_due) |n| self.arm(n);
    }

    /// Arms the unregistered timer for `at` by initializing it afresh and
    /// adding it, which zio documents for a timer that is not registered
    /// (pinned 53ed3c377317): from `timerCb`, the completion whose callback
    /// is running, `Completion.callback` (src/ev/completion.zig:294-305,
    /// https://github.com/lalinsky/zio/pull/929): "for a completion with
    /// neither `rearm` nor a group or queue owner the loop does not touch it
    /// after the callback returns. The callback may therefore free it, or
    /// reuse its memory for the next operation, of the same or another type,
    /// and `add` it again"; after `Loop.clearTimer` returned true
    /// (src/ev/loop.zig:724-726): "the timer is the caller's again: it was
    /// disarmed here (or was never armed), and its callback will not run".
    /// The pool does not use `Loop.setTimer`, whose documentation does not
    /// say whether it may be called from the timer's own callback.
    fn arm(self: *Pool, at: zio.Timestamp) void {
        std.debug.assert(self.timer_due == null);
        self.timer = ev.Timer.init(.{ .deadline = at });
        self.timer.c.callback = timerCb;
        self.timer.c.userdata = self;
        self.timer_due = at;
        self.loop.add(&self.timer.c);
    }

    fn earliest(a: ?zio.Timestamp, b: zio.Timestamp) zio.Timestamp {
        const x = a orelse return b;
        return if (b.value < x.value) b else x;
    }

    /// The deadline timer ended: everything due by the clock now
    /// expires. A queued query is unlinked and answered `57014` (never
    /// sent); a busy slot's session is disposed of and its query abandoned,
    /// or answered when its answer is already known (`Slot.expire`); the
    /// connect in flight ends (`Slot.connectExpire`).
    /// Deliveries run from `dispatch`, after the state is repaired; one a
    /// connect's end makes at once (`failWaiting`) may submit, and that
    /// query waits for the `dispatch` below, which re-arms the timer for
    /// what still runs (`rearm`, `arm`).
    fn timerCb(lp: *ev.Loop, c: *ev.Completion) void {
        const self: *Pool = @ptrCast(@alignCast(c.userdata.?));
        ownLoop(lp, self.loop);
        self.timer_due = null;
        std.debug.assert(!self.dispatching);
        self.dispatching = true;
        const t = now();
        var prev: ?*Waiter = null;
        var it = self.head;
        while (it) |w| {
            it = w.next;
            if (!due(w.deadline, t)) {
                prev = w;
                continue;
            }
            if (prev) |p| p.next = w.next else self.head = w.next;
            if (self.tail == w) self.tail = prev;
            w.next = null;
            ekk_query_drop(w.query);
            w.query = null;
            self.ready(w, ekk_pg_error("57014", "the query's deadline passed before it was sent"));
        }
        for (self.slots) |*s| switch (s.state) {
            .busy => if (due(s.waiter.?.deadline, t)) s.expire("the query's deadline passed; its session was closed, so whether it took effect is unknown"),
            .connecting => if (due(s.connect_deadline, t)) s.connectExpire(),
            else => {},
        };
        self.dispatching = false;
        self.dispatch();
    }

    fn find(self: *Pool, state: SlotState) ?*Slot {
        for (self.slots) |*s| if (s.state == state) return s;
        return null;
    }

    /// The connect in flight failed (`pg`, `message` as for `failWaiting`).
    /// While a session is busy, the queries waiting keep waiting, each to
    /// its own deadline, for that session to finish (`connect_failed`);
    /// otherwise they fail now.
    fn connectFailedFor(self: *Pool, pg: ?*Session, message: ?[*:0]const u8) void {
        if (self.find(.busy) != null) {
            self.connect_failed = true;
            return;
        }
        self.failWaiting(pg, message);
    }

    /// The connect in flight failed: every query waiting now fails once with
    /// `08006` (`message`, else `pg`'s message when given). A query
    /// submitted from one of these deliveries joins a fresh queue, for the
    /// next connect.
    fn failWaiting(self: *Pool, pg: ?*Session, message: ?[*:0]const u8) void {
        std.debug.assert(self.attempt != null);
        var it = self.head;
        self.head = null;
        self.tail = null;
        while (it) |w| {
            it = w.next;
            w.next = null;
            ekk_query_drop(w.query);
            w.query = null;
            self.complete(w, if (message) |m| ekk_pg_error("08006", m) else ekk_pg_lost(pg));
        }
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

    /// The loop's shutdown drain ended: a waiting query is answered
    /// `error 57014` (never sent), a running one `abandoned 57014` (or its
    /// own answer, when already known) with its session closed
    /// (`Slot.expire`), the connect in flight ends, and from
    /// now on `submit` answers every query at once, unsent. Every result is
    /// delivered before this returns; a delivery that submits is answered
    /// in the same run of `dispatch`, which here does not yield however
    /// long the chain (`chain_inline`), since the drain closes every
    /// connection right after this returns (serve.zig, `drainCb`).
    pub fn abort(self: *Pool) void {
        std.debug.assert(!self.dispatching);
        self.stopping = true;
        self.aborted = true;
        self.dispatching = true;
        while (self.dequeue()) |w| {
            ekk_query_drop(w.query);
            w.query = null;
            self.ready(w, ekk_pg_error("57014", "the server's shutdown drain ended (--drain-ms) before the query was sent"));
        }
        for (self.slots) |*s| switch (s.state) {
            .busy => s.expire("the server's shutdown drain ended (--drain-ms); the query's session was closed, so whether it took effect is unknown"),
            .connecting => s.teardown(),
            else => {},
        };
        self.dispatching = false;
        self.dispatch();
    }
};
