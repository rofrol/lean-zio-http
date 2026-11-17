# Lean HTTP/1.1 server on zio.ev

A Lean 4 HTTP/1.1 server library on per-core `zio.ev` event loops, with
PostgreSQL access from the loops. It was written for ekklesiai.org and
started there as a spike; ids of finished items below (`dqsipn`, `7bccgi`,
`2l6rcv`, ...) name that project's queue items, where the history was kept.
Open work on the server is queued in this repository, in `issues/` (order in
`issues/ORDER`), and named below by its ids here (`53rwgc`, ...). Decision
D1 (the HTTP/1.1 parser) is recorded in ekklesiai.org, in its decision
record 0001 (`docs/decisions/0001-lean-http-server-on-zio.md`, section "D1:
the HTTP/1.1 parser"), which names this queue's item 53rwgc as pihgvg. The
sections from
"`Std.Http.Protocol.H1` compared with the hand-written parser" on are the
spike's measurements, kept as they were written.

## Using it from another Lake package

```lean
require lsrv from git "https://github.com/rofrol/lean-zio-http" @ "<commit>"
```

The package builds its Zig side itself: `extern_lib zsrv` in `lakefile.lean`
runs `zig build` in `zig/` (Zig 0.17; `ZIG_OPTIMIZE` picks the optimization,
ReleaseSafe by default) and Lake links `libzsrv.a` into every executable of
the requiring package. On Linux it builds for the glibc the Lean toolchain
links programs against (`lib/glibc/libc.so` of the toolchain, 2.26 for the
pinned one), not the host's, so the archive calls no libc function that glibc
lacks. An executable that runs the transport also links
libpq: give it `moreLinkArgs := #["-lpq"]` and put `pg_config --libdir` on
`LIBRARY_PATH`. Its composition root imports `Server.Transport`, one adapter
(`Server.H1Adapter`) and the application, and declares
`server_exports (Server.H1Adapter.adapter own app)`, where `own`
(`Server.Response.OwnFields`, `{}` for none) holds header fields for the
responses the server writes itself; see `Main.lean` and `Fixture.lean`. Pin the same
Lean toolchain as `lean-toolchain` here.

## Modules

Lake libraries (`lakefile.lean`) and what each may import. `lsrv-arch`
(`Arch.lean`) reads the imports of every `.lean` file of the package and
fails on an import its module's rule does not allow, and on a file no rule
names, so a new module, an application included, fails until its row is
added; `bench.sh` runs it, and runs it on a fixture package whose forbidden
imports it must report.

| module | role | may import |
|---|---|---|
| `Server.Query` | a database query and its result as values, and `Await`, a computation that may wait for queries | nothing |
| `Server.Wire` | the limits, `Server.Reply` (the adapter's answer to the bytes buffered on a connection, its responses functions of the clock, `Server.Dated`) and `Server.Adapter`, the adapter's state kept between receives and the law `Adapter.Incremental` it keeps | `Server.Query` |
| `Server.Handler` | the interface the application implements: `Request → Await Response` | `Server.Query` |
| `Server.Conn` | a connection's lifecycle: one state type and a pure `step` over the loop's events, with theorems | `Server.Wire` |
| `Server.Transport` | the loop's Lean side: `ekk_serve`, the command line, the `server_exports` command that exports the loop's entry points | `Server.Wire`, `Server.Conn` |
| `Server.Response` | writes and checks responses, for both adapters | contracts |
| `Server.H1Adapter` | the production HTTP/1.1 adapter, `Std.Http.Protocol.H1` (D1) | contracts, `Server.Response`, `Std.Http.Protocol.H1` |
| `Server.HandParser` | the hand-written parser: test comparator and rollback until item 53rwgc, then deleted (D1) | contracts, `Server.Response` |
| `App.Hello` | the benchmark application | `Server.Handler` |
| `App.Fixture` | the boundary tests' application | `Server.Handler`, `App.Hello` |
| `App.Db` | the PostgreSQL tests' and benchmark's application | `Server.Handler`, `App.Hello` |
| `Main`, `Fixture`, `MainDb` | composition roots `lsrv`, `lsrv-fixture`, `lsrv-db`: H1 and one application | `Server.Transport`, `Server.H1Adapter`, `App.*` |
| `MainHand`, `FixtureHand` | `lsrv-hand`, `lsrv-fixture-hand`: the same with the hand-written parser | `Server.Transport`, `Server.HandParser`, `App.*` |
| `Test`, `Bench`, `Compare`, `Corpus`, `Arch` | tests and measurements | anything |

"Contracts" are `Server.Query`, `Server.Wire` and `Server.Handler`. The
transport knows neither HTTP nor the application; the application sees
neither the transport nor `Std.Http`. The handler is pure: it answers
`Await.done response`, or `Await.query q k`, which asks the loop to run `q`
and continues with `k` on its result (`Await` is a monad, so a handler
writes `match ← Await.run q with ...`). This replaced `Request → Response`
with no compatibility layer. The PostgreSQL adapter is part of the loop
(`zig/src/pg.zig` and `zig/src/pg.c`); Lean sees
only `Server.Query` values.

- `zig/` (the transport's loop): a static library, built ReleaseSafe by
  `bench.sh` unless `ZIG_OPTIMIZE` says otherwise. One `zio.ev` loop per
  thread, all accepting on one listening socket on 127.0.0.1:8083 (`--port`
  picks another; 0 asks the kernel for a free one). Once it listens it prints
  `listening on 127.0.0.1:PORT with N loops, at most M connections` to
  stderr, with the port it got, and `ready` once every loop has registered
  its acceptor. When the socket cannot be had (a port another process holds)
  it prints the failed call, the address and the errno, such as `cannot bind
  127.0.0.1:8083: errno 48 (ADDRINUSE)`, and exits 1. The checks and
  benchmarks start every server on port 0 and read its address from that
  line, so they share no fixed port with checks running beside them. The loop keeps no
  protocol or buffering state: each connection holds a Lean `Conn.State`,
  reports the outcome of every operation to it through `src/glue.c`, and
  performs the action it answers. Worker threads call
  `lean_initialize_thread`, which libleanrt exports but `lean.h` does not
  declare. It keeps at most one operation in flight per connection and ends
  the process when a completion finds none outstanding; beside a send it may
  also keep a readiness poll while the send waits on the kernel, which
  carries no data (section "Deadlines"),
  and a close waits for that poll's completion. Reusing a
  connection's completion from its own callback relies on zio's contract
  (pinned 830564437b2c, `src/ev/loop.zig` `finishCompletion`): the completion is
  marked dead before its callback runs, and for a completion without a group
  owner the callback is the last thing the loop does with it. Each loop
  also owns a PostgreSQL pool (`src/pg.zig`, section "PostgreSQL"). The
  library needs libpq's headers (`-Dpq-include`) and the servers link
  `-lpq`: libpq 14.6, 15.1, or 16 and later (pipeline mode, and single-row
  mode reset after each pipelined query); a server with `--pg` exits with
  status 1 at startup when the libpq it runs is older.
- Command line: `lsrv [THREADS] [--port N] [--max-conns N] [--pg CONNINFO]
  [--pg-conns N] [--idle-ms N] [--head-ms N] [--body-ms N] [--write-ms N]
  [--pg-query-ms N] [--pg-query-max-ms N] [--pg-connect-ms N]
  [--pg-statement-ms N]` (`--pg-conns`, default 4, is per loop; without
  `--pg` no pool is made and every query fails with `08006`; the four
  connection budgets, in milliseconds, are in "Deadlines" below, the four
  database budgets in section "PostgreSQL", "Deadlines"), then the test
  settings:
  `--chunk N` caps every receive and send at N bytes, `--fail-every N`
  reports every N-th completed receive and every N-th completed send to Lean
  as failed, `--trace` prints `open <id>` and `free <id> <operations>
  <injected receive failures> <injected send failures>` per connection,
  `query <id>` when a connection hands a query to the pool, `pg closed`
  when a pool slot has ended its PostgreSQL session, and
  `stop <receives> <sends>` when a loop's shutdown starts, and
  keeps freed connections allocated, so a late completion hits that check,
  and `--crash-after-recv N` and `--crash-after-send N` kill the process with
  SIGKILL right after the N-th successful receive or send, before Lean hears
  of it.
- `dusty-hello/`: the same route on dusty, the HTTP library on zio.
- `bench/`: Go's `net/http` with the same route (`goserver`) and with
  `App.Db`'s `/db` route over a pgx pool (`pgserver`), end-to-end checks over
  real sockets (`check`), the boundary tests (`boundary`, below), the
  PostgreSQL tests (`dbcheck`, below), and a closed-loop keep-alive load
  generator (`load`) that counts only responses with status 200 and the
  expected body and fails on anything else.

## Production contract

- **Effects precede their record, and all state is volatile.** A receive or
  a send has happened in the kernel before its event reaches `Conn.step`; a
  close is chosen before it is performed. Nothing survives the process. A
  crash between an effect and its record can leave a peer with any prefix of
  a response, possibly empty, and its request unanswered; a restarted server
  knows nothing of it. HTTP clients see a closed connection, which they
  already handle (consult round 20261116-042512-dc1f). `bench/boundary`
  kills the server right after a receive (the client sees no byte) and right
  after the third 7-byte send (the client sees at most those 21 bytes, a
  prefix of the response), then checks that a fresh server serves normally.
- **Requests.** HTTP/1.0 and 1.1 through `Std.Http.Protocol.H1`: a head of at
  most 8,192 bytes in all (H1 bounds the request line and the header block
  separately; the adapter answers a longer head, complete or not, with 431),
  at most 100 fields, a Content-Length body of at most 8,192 bytes,
  pipelining. So every request the adapter waits for fits in the connection's
  buffer (`inCap`); `lsrv-test` feeds a 10,000-byte head and the largest body
  through `Conn.step` and expects 431, not a silent close. H1 validates the
  request line, the method (unregistered: 501), the version (505), the
  request-target's form and URI syntax, exactly one Host with valid syntax in
  HTTP/1.1, and the framing; a chunked body gets 501. CONNECT gets 501 and
  never reaches the application (no tunnels). A rejected request gets its
  status and the connection closes.
- **`Expect: 100-continue`.** When a head asks for it in HTTP/1.1 and its body
  is not complete, the connection sends `HTTP/1.1 100 Continue` once and
  waits for the body (`Server.Reply.continue`, `Conn.serve_continued`); a
  body sent with the head gets the final response directly, and HTTP/1.0 gets
  no interim response. Other expectations are ignored.
- **Bounded output.** A response is written whole into one buffer of at most
  `maxResponseBytes` (65,536) bytes and sent in pieces of at most 8,192 bytes
  (the loop's send buffer). A larger response, a status outside 200-599, a
  body with 204, 205 or 304, a field the adapter owns (Content-Length,
  Transfer-Encoding, Connection, Date, Keep-Alive, Upgrade, Trailer) or a
  field name or value that is not valid becomes `500` with
  `Connection: close` (`Server.Response.check`). Streaming larger bodies is
  not offered; it would change the handler interface.
- **Deadlines.** Each connection has one deadline at a time, set by its
  phase, and while it writes a response, also the head budget of a request
  pipelined behind it; when one passes, the connection closes silently: no
  408, and bytes already sent stay sent. Every budget is a peer's budget,
  configurable from 1 ms to below 2^32 ms (another value: exit status 2):
  keep-alive idle `--idle-ms` 60,000 (nginx's `keepalive_timeout` default is
  75 s), from the end of a response with nothing buffered to the next byte;
  request head `--head-ms` 10,000 (H2O's header timeout), absolute, from the
  accept for the first request and from its first byte for a later one, also
  while the previous response is still being written (`Conn.Phase.ahead`;
  the end of that response keeps the period, `Conn.step_sent_handoff`); body
  `--body-ms` 30,000 from the head's acceptance, across an interim
  `100 Continue`; response write `--write-ms` 30,000 from the start of each
  response. A connection waiting for a query runs under no deadline of its
  own: the query's completion deadline bounds that wait, and its expiry
  reaches the handler as the query's result (section "PostgreSQL",
  "Deadlines"). `Conn.step` takes `Event.expired kind generation`:
  the loop's timer reports the phase it was armed for, and an expiry of an
  earlier phase is stale and changes nothing (`Conn.step_expired_stale`,
  `expired_old_stale`). A later request's first byte is known at the
  receive that brought it, when it came with the previous request; otherwise
  the loop, while it writes a response with nothing buffered and the send
  waits on the kernel, keeps a readiness poll on the socket beside the send
  and reports `Event.arrived` when the socket becomes readable (the bytes
  stay in the kernel; a peer's end of input counts too, and the receive
  after the response reports it). A send the kernel takes whole at its
  submission starts no poll: the loop goes on at once with the response's
  next send, which gets the poll if it waits, or with the receive that sees
  what arrived, so that head's budget starts late by at most the server's
  own work in between. The poll costs a probe and a
  registration (section "PostgreSQL" measures that cost on macOS), which a
  poll on every keep-alive response would add to each request.
  Bytes that arrive while a query runs are seen when its response starts, so
  that head's budget starts late by at most the time the handler's queries
  take, each bounded by its completion deadline: for a request pipelined
  behind a query, the query deadlines bound how late its head budget starts;
  they do not make that budget absolute from the head's first byte. When the
  head budget ends during the write and the next request's head is already
  complete in the server's buffer, the budget ends without a close
  (`Conn.step_expired_ahead_complete`); a head still in the kernel is not
  read before the response is written, so it closes even when complete
  (`Conn.step_expired_ahead_partial` covers the partial head). Which of a due timer and
  a ready receive or send wins is the order zio runs their callbacks in; an
  expiry counts once it is reported, and a completion that arrives after it
  is not reported. The shutdown's own drain bound is a separate item.
- **Admission.** At most `--max-conns` connections (default 4,096) are open
  process-wide; the rest wait in the kernel's listen queue. A loop arms its
  accept only with a free slot, and an accepted connection keeps the slot
  until its close; a loop that finds none pauses its acceptor and re-arms it
  when one of its connections closes (the liveness argument is next to
  `slots_used` in `zig/src/serve.zig`). At startup the soft `RLIMIT_NOFILE`
  is raised to fit `--max-conns` plus a reserve, or the server refuses to
  start.
- **Accept errors.** Errors of the one pending connection (`ECONNABORTED`,
  protocol and firewall errors, `ENETDOWN`) and a spurious `EAGAIN` re-arm
  the accept. Exhaustion (`EMFILE`, `ENFILE`, `ENOBUFS`/`ENOMEM`) and errors
  of the listening socket itself end the process with status 1 and a
  `fatal:` line: the descriptor limit was checked at startup, so exhaustion
  comes from outside the server and nothing in it waits for that to end; a
  supervisor restarts it. Linux's accept(2) lists further errors of a
  pending connection (`ENETUNREACH`, `EHOSTUNREACH`, `EHOSTDOWN`, `ENONET`,
  `ENOPROTOOPT`, `EOPNOTSUPP`: "treat them like EAGAIN by retrying"). The
  pinned zio maps them to `Unexpected` (through `unexpectedError`, which logs
  "please file a bug report") or `OperationNotSupported`, which also stand
  for errors of a broken listening socket (`src/os/net.zig`,
  `errnoToAcceptError`), so they end the process. In the Linux sources read
  (v5.4, v6.1 and mainline aebb727, on 2026-11-16), TCP's accept, for IPv4
  and IPv6 and also through io_uring, passes no pending connection's network
  error to the caller: `inet_accept` returns only the error of
  `inet_csk_accept`, which fails only with `EINVAL` (not listening),
  `EAGAIN` or the error of its wait for a connection. That is a reading of
  those revisions, not a guarantee for every kernel or security module. zio
  documents no meaning for these errnos and no passage names them as a
  limitation; whether its mapping is a bug stays unresolved, and the owner
  decides whether anything follows (item xihdtw's outcome). Re-arming on
  `Unexpected` unconditionally would repeat a persistent error of the
  listening socket.
- **Shutdown.** SIGTERM or SIGINT starts a graceful shutdown: each loop stops
  accepting (its armed accept is canceled; a connection accepted meanwhile is
  closed), cancels every receive in flight and declines every later one
  (`Conn.Event.refused`, which closes the connection), lets every send run to
  completion, so a response already started arrives whole and requests
  already buffered are answered, and its `loop.run` returns once nothing of
  it is in flight: every completion queued before the stop has been
  dispatched. When all loops have returned the process prints `stopped` and
  exits with status 0. A peer that does not read its response holds the
  shutdown at most for the write budget (`--write-ms`), after which its
  connection closes; a shorter bound for the whole shutdown is the
  supervisor's (SIGKILL).
  A query in flight or waiting for a pool slot also holds the shutdown
  until it is answered, at most for its completion budget (section
  "PostgreSQL", "Deadlines").
- **Transport tests.** `zig build test` in `zig/` (`bench.sh` runs it) also
  runs `src/serve_test.zig`. It drives `serve.zig`'s loops on real sockets,
  with a fake of `glue.c` that reports every call as an event, and checks
  the zio behavior the shutdown and admission rely on. (1) The shutdown's
  cancels never call back into a connection while the shutdown is walking
  the list of connections: each canceled receive comes back once, as a
  refusal. (2) A receive whose result is already queued when the cancel
  comes is dispatched once, with that result. (3) Admission works across
  two loops: after each step the test has seen (for a close, once the
  closing loop has acknowledged that the close finished), each loop
  acknowledges a snapshot of its own admission state, so the test sees both acceptors
  pause when the server is full, a connection wait in the listen queue,
  and the loop whose connection closed re-arm and take it. (4) The loop
  does not take its stop while the stop's notifier is still waking it.
  zio 9bef33d's `Async.notify` could let the loop take the stop, end and
  close its poller in `deinit` before notify's own wake syscall, which then
  panicked instead of the process exiting with status 0
  (https://github.com/lalinsky/zio/issues/927). The pinned zio fixes it
  (https://github.com/lalinsky/zio/pull/928): notify "is now safe to call
  at any time while the `Async` itself is alive", so the signal thread
  calls it plainly; each loop's `stop` lives in `loops`, which is never
  freed. `notify` has no point a test can pause it at, so the test
  performs its steps itself, as zio's own test does
  (`src/ev/test/async_stress.zig`), stops it before its wake syscall, lets
  a byte wake the loop, and checks that serve's shutdown waits until the
  notify finishes. With 9bef33d's steps (its `pending` was a plain counter)
  the loop takes the stop at once and the test fails.
  (5) Deadlines: a timer that ends closes the connection, and the receive
  it canceled is not reported; an expiry run before a ready receive closes
  and the bytes are not reported; a receive within one period keeps its
  armed timer and due time; a receive run before a due expiry wins, and the
  replaced deadline's expiry is not reported, only the new one's; a timer
  disarmed while its callback is already on its way is retired, and its
  callback reports nothing. Each order is forced (a timer set due at once
  after the receive is ready, or a test timer in the same batch), not
  timed. `bench/boundary`'s `deadlines` scenario checks the idle, head and
  body expiries end to end with short budgets.
- **Not yet:** chunked
  request bodies, percent-decoding and query parsing, Go's larger limits.

## PostgreSQL

A handler that answers `Await.query q k` puts its connection in
`Conn.Phase.querying k`; the loop runs `q` on its own pool and feeds the
result back as `Conn.Event.answered`, and `k`'s answer continues the
connection (another query or the response). The connection does nothing
else meanwhile; the loop serves its other connections (`Conn.step_query`,
`bench/dbcheck`'s slow-query test).

- **Pool.** Each loop has its own pool of at most `--pg-conns` libpq
  connections in non-blocking mode, registered with its own `zio.ev` loop
  only (no locks, no sharing between loops; one loop's busy pool does not
  borrow another's idle connections). A query that finds no idle
  connection waits in the loop's FIFO queue, which holds at most one query
  per HTTP connection. Connections open on demand, while queries wait and a
  slot is free, one at a time per loop: a connect is not tied to a query,
  and the connection it opens serves the queue's head like any idle one.
  So a burst on a cold pool opens its connections one after another.
  zio's socket registry keeps a registration per descriptor until a
  `NetClose`, while libpq closes and replaces its own socket, so the pool
  polls a duplicate of libpq's descriptor that it owns and closes with
  `NetClose` (`zig/src/pg.zig`, its header).
- **Statements.** Each connection prepares a statement for each distinct
  `Query.sql` on its first use (one round trip: Prepare, execute and Sync in
  libpq's pipeline mode) and executes it by name after that, as pgx does;
  past 64 statements on a connection further texts run unnamed. So a query
  must not deallocate statements (`DEALLOCATE`, `DISCARD ALL`). A cached
  statement that went stale (its result type changed after a schema change:
  `0A000` raised by PostgreSQL's `RevalidateCachedQuery`; or the server no
  longer has it: `26000`) fails that query with PostgreSQL's error, which is
  not resent, and is forgotten: the text's next use prepares it again, under
  a name the connection never used, so it cannot collide with the statement
  the server still holds. A connection closes after the query that leaves 64
  such forgotten statements, which bounds what it keeps on the server.
  Parameters and results are text; one statement per query.
- **Results and errors.** Every query is answered exactly once: rows (text
  values, `none` for NULL, invalid UTF-8 replaced), PostgreSQL's error with
  its SQLSTATE, a pool error (`Query.Result.error`): `08006` when the
  connection could not be made, or was found lost before the query was
  handed to libpq (`ekk_pg_send` checks the connection's status before
  any libpq call), `57014` when the query's deadline passed before it was
  sent, `22023` for a `Query.timeoutMs` outside 1 to the ceiling, `54000`
  for a query that cannot be sent (a NUL byte, more than 65,535
  parameters), none of which ran; or the query abandoned
  (`Query.Result.abandoned`): `08006` when the connection was lost after
  the query was handed to libpq (also for a query in flight when the
  server restarts: libpq documents no point before which a failed send or
  an unflushed buffer proves nothing reached the server), `57014` when its
  deadline passed after that ("Deadlines"), and `54000` for a result over
  `Query.maxResultBytes` (1 MiB, charged for every object of its Lean
  value before it is built: each row and field, `NULL` and empty ones
  included, and each string with its header). Rows
  are received one at a time (libpq's single-row mode) and charged as they
  arrive; at the row that crosses the bound the rows gathered are
  released, the query is answered `abandoned "54000"` once and its session
  is closed without reading the rest. So whether the statement took effect
  is unknown (a write with a large `RETURNING` may have been committed, or
  rolled back when the server noticed the closed connection; effects
  outside transactions, such as sequences, stay). `abandoned` says that
  structurally, so a caller need not read the message; it promises no
  rollback and never authorizes sending the statement again, which only
  the caller's own means (an idempotent statement, a key it checks) can
  make safe. An `error` does not prove the opposite in general (PostgreSQL's
  own errors are its own word); an unknown outcome the pool knows of is
  answered `abandoned`. A query is never retried: once it may have reached
  the server, a lost connection or an expiry abandons it, and its outcome
  is unknown (a write may have been committed); the next query opens a
  fresh connection. Likewise a process
  that ends after a query was sent leaves its outcome to PostgreSQL, as
  for any client that disconnects. A connect that fails fails every query
  waiting at that moment, each once with `08006`, also when other
  connections of the pool are busy; a query submitted later starts the
  next connect. So with the database down a loop has at most one connect
  in flight, and a flood of requests is answered from it rather than with
  a connect each; there are no retries, backoff or circuit breaker, so this
  bounds concurrent connects, not their rate while the database stays down.
  `App.Db` answers class 08 with 503, `57014` with 504, other errors with
  500, and an abandoned query with the same status and `outcome unknown`
  in its body.
- **Deadlines.** Each budget is an external database budget, configurable
  from 1 ms to below 2^31 ms (another value: exit status 2). A query's
  completion deadline runs from its submission to the pool to its complete
  result, queueing and connecting included: `--pg-query-ms` 5,000 by
  default; a handler may ask for another with `Query.timeoutMs`, up to
  `--pg-query-max-ms` 5,000 (a value of 0 or over it is answered `error
  22023` unsent). A connect has `--pg-connect-ms` 5,000 from its start to a
  connection ready for queries, enforced by the pool's timer around libpq's
  asynchronous connect (libpq's `connect_timeout` does not bound
  `PQconnectPoll`); a query waiting for it keeps its own earlier deadline.
  Every session starts with PostgreSQL's `statement_timeout` at
  `--pg-statement-ms` 4,000, through libpq's `options` startup parameter
  after the conninfo's own `options` (or `PGOPTIONS`); a conninfo or
  `PGSERVICE` naming a service is refused at startup, since the service
  file's options would be replaced, and so are options ending in an
  unpaired backslash, which would escape the appended one. So PostgreSQL usually ends a long
  statement itself (`error 57014`, the session serves on), but that does
  not bound the pool's wait: queueing, transmission and the server's
  scheduling come before its timer starts. One timer per pool is armed for
  the earliest deadline; its callback expires what is due at that moment
  and re-arms. A query that expires in the queue (or while the connect
  runs) is unlinked and answered `error 57014`; one already handed to libpq
  is answered `abandoned 57014` and its session closed at once with
  PQfinish, without PQcancel: the backend may run on until its
  `statement_timeout` or until it next writes to the closed connection, a
  write may commit, and the query is never sent again. A connect that ends
  at its deadline fails the queries waiting with `08006`, as a failed
  connect does. Expiry is judged against the pool's state when the timer's
  callback runs (the waiter still queued, the slot still busy with it, the
  slot still connecting), so an expiry whose completion came first finds
  nothing due and changes nothing; which of a due timer and a ready result
  wins is the order zio runs their callbacks in, as for the connections'
  deadlines. The expiry reaches the handler as the query's result, and its
  response is the handler's: no response byte of the request is sent while
  its query runs, so `App.Db`'s 504 is always possible.
- **Liveness.** An idle connection keeps its receive armed, so a connection
  the server closed is ended when the loop handles its EOF. This is best
  effort: a query the loop dispatches before handling the EOF is answered
  `08006`: `error` when libpq already knew the connection had failed,
  `abandoned` once it was handed to libpq.
- **Sessions.** Each query is its own implicit transaction. A query that
  leaves a transaction open or failed (`BEGIN`) is answered `25000` and its
  session is closed, which rolls the transaction back, so no query runs in
  another's transaction. Other session state (`SET`, session-level advisory
  locks, temporary tables) stays with the session for later queries of any
  request; queries must not change it (`Server.Query`).
- **Connection string.** `--pg` is a libpq conninfo; the pool adds
  `client_encoding=UTF8` and the `options` that set `statement_timeout`
  ("Deadlines"). It must name a Unix socket directory or a
  `hostaddr`: libpq resolves a host name synchronously, which would block
  the loop.
- **Tests.** `bench/dbcheck` runs `lsrv-db` against the private cluster.
  What a real cluster cannot force is tested deterministically by
  `zig build test` in `zig/` (`bench.sh` runs it). `src/pg_test.zig` runs
  `pg.zig`'s pool on a real loop and real sockets with a scripted fake in
  place of `pg.c`: a partial flush with both polls outstanding and the
  write completion arriving after the slot went idle, a session ended
  (COPY) with both polls outstanding, synchronous chains of 10,000
  failing queries (no slots, the database down) that stay iterative,
  deadlines (an expiry in the queue unlinks only that query, a busy
  query's expiry closes its session without reading, which never serves
  again, a connect's deadline fails its waiters, a waiter's own earlier
  deadline, a timer callback after the completion changing nothing, a
  budget refused with `22023`), and a lost connection before the query
  reached libpq (`error`) and after (`abandoned`: a failed send, flush or
  read).
  `src/pg_glue_test.c` runs `pg.c` and the real libpq against a fake
  PostgreSQL server on a Unix socket, each reply delivered whole, a message
  at a time and a byte at a time: command boundaries and Sync, errors,
  COPY in and out, a transaction left open, a connection lost mid-reply,
  cached statements going stale (`0A000` from `RevalidateCachedQuery` and
  `26000` forget the statement, another `0A000` keeps it, a failed
  transaction still closes the session, 64 stale statements close it), and
  single-row collection: after every piece the rows held are exactly the
  rows received (first use, cached and unnamed executions), zero rows keep
  their columns, rows then an error answer the error, a result at exactly
  the bound is answered, and one byte over it, or a single field over it,
  ends the session at the row that crosses it, answered `abandoned`
  (constructor 2), while a query with a NUL character is an `error 54000`
  (constructor 1) that sends nothing. A connection lost mid-reply is
  `abandoned 08006`, one whose EOF libpq saw before the next query refuses
  it unsent (`error 08006`), and every session's startup packet carries
  the startup options (`ekk_pg_options`: merged with the conninfo's or
  `PGOPTIONS`, refused for a service or for options ending in an unpaired
  backslash).
  `bench/dbcheck` checks the deadlines against the private cluster (a query
  expiring in flight and in the queue, `statement_timeout`, a connect to a
  listener that never answers) and changes a column's type under a cached statement and back,
  and runs an `INSERT ... RETURNING` over the bound (abandoned with
  `54000`, the session closed, the insert wholly applied or not at all).
  A chain of queries that fail synchronously, each asked again from its
  error, runs entirely inside the `submit` that started it: the loop serves
  nothing else until the chain ends.
- **Bounded only in part:** the pool gathers at most `Query.maxResultBytes`
  of a result, but libpq takes in a whole protocol message before the pool
  sees it, so one row larger than the bound costs its full size (in libpq's
  input buffer and again in its result) before the session is closed, and
  libpq's input buffer keeps the size of the largest message a session
  received until the session is closed.

Measured by `bench.sh` (M1, 2026-11-16, 8 loops with 4 connections each
against Go's `net/http` with one pgx pool of 32, both on the same private
cluster, `GET /db?id=42`, 10 s per run):

| server | c=1 req/s | CPU µs/req | c=64 req/s | CPU µs/req |
|---|---:|---:|---:|---:|
| lean-db | 12,512 | 34 | 78,178 | 44 |
| go-db | 11,745 | 68 | 71,610 | 51 |

lean-db reaches 1.06 and 1.09 of Go's throughput (goal: 0.9). Two choices
decided it, measured while building the pool (5 to 10 s runs): readiness
through a one-byte peeking receive instead of zio's `NetPoll`, whose
`poll(2)` probe cost more CPU than the receive and the send together on
macOS (c=64 from 0.86 to 1.07 of Go), and prepared statements (c=1 from
0.78 to 0.90 of Go with the probe; without them, after the probe change,
0.91 at c=1 and 0.98 at c=64). At 64 connections lean-db's p99 latency is
higher than Go's (3.6 against 2.4 ms): HTTP connections spread unevenly over
the loops, and each loop's queries wait for that loop's slots only.

## Memory

Three kinds of statement, kept apart: lengths that `Conn.step_inv` proves,
allocations derived from the code of the runtime and its allocators (for the
adapter's state also checked against the blocks a state actually holds), and
resident set growth that `bench/boundary` measures. A connection holds at
most 715,228 bytes (698.5 KiB) of live blocks besides its small Lean
objects, most of them H1's parsed request-target while a request is
incomplete (below): 2.73 GiB at the default 4,096 connections. This replaces
the statement of about 98 KiB per connection, withdrawn when the adapter's
state was measured (issue es53kx).

**Lengths** (proved, `Conn.step_inv`): the Lean buffer of unconsumed bytes
holds at most `inCap` = 16,388 bytes and a response being sent at most
`maxResponseBytes` = 65,536.

**Allocations** (derived; toolchain nightly-2026-11-14, its runtime at
lean4 commit 62e0cf0, mimalloc 3.4.5; a block size is what the toolchain's
`mi_good_size` returns for the object, on the M1):

- The loop's connection: a 16,712-byte `Conn` (`@sizeOf`, Zig 0.17.1) from
  `std.heap.c_allocator` (`zig/src/serve.zig`), a 20,480-byte malloc block
  (`heap -s`).
- A `ByteArray` is one mimalloc block holding a 24-byte header and its
  capacity. `extract` copies with capacity equal to the length; appending
  (`++`, `push`) to an array whose capacity is too small copies it with
  twice the size needed (`lean_sarray_ensure_capacity`, `exact := false`);
  a shared array is copied with its capacity
  (`lean_sarray_ensure_exclusive`).
- The buffer: allocated with capacity `inCap` (`Conn.initial`); once a
  request is consumed, the `extract` of the rest; a receive is appended only
  when the result fits `inCap`, so a growth gives at most 2 × `inCap` =
  32,776: a block of at most 40,960 bytes. While a final response is sent
  the buffer is the rest of the receive that completed the request, under
  8,192 bytes (below), copied exactly: a block of at most 10,240.
- A response: `Server.Response.write` builds the head in a scratch array,
  dropped within the step, then allocates capacity exactly the head and the
  body it sends and appends both, so neither append grows it. A response
  kept is at most 65,536 bytes (`render` replaces a larger one), so its
  capacity is at most 65,536: a block of at most 81,920 bytes, of which only
  the pages written need be resident (`lsrv-test` checks the capacity and,
  at the limit, the block). The fixture's largest response (60,121 bytes)
  is a 65,536-byte block.
- The adapter's initial state is one object shared by every connection
  (H1's is a closed term, `lean_obj_once` in the generated C), so a
  connection whose adapter is at `init` holds none of its own; the interim
  `100 Continue` is a shared constant too.

So a connection holds, besides its small Lean objects (the state, phase and
action constructors, tens of bytes each):

- while reading, and while sending the interim response: at most 20,480 +
  40,960 = 61,440 bytes, plus the adapter's state, with H1 at most 653,788
  (below): 715,228 bytes (698.5 KiB) in all, the most of any state;
- while sending a final response: at most 20,480 + 10,240 + 81,920 =
  112,640 bytes (110 KiB), the adapter at `init`;
- while waiting for a query: the connection and an exact buffer of under
  8,192 bytes, plus the `Server.Query` and continuation the handler built
  (bounded by what it builds), and while the continuation turns it into the
  answer a result whose Lean value costs at most `Query.maxResultBytes`
  (counted with object headers; libpq's buffers are the pool session's,
  section "PostgreSQL", "Bounded only in part").

These count the arrays the connection's state holds; a copy of buffer bytes
that the adapter keeps is the adapter's (below). Allocations made and
dropped within one step are not counted; a loop runs one step at a time,
so they are per loop, not per connection.

The buffer and a full response are not both at their maximum at once: a
connection receives only while it is not sending, and the loop receives at
most 8,192 bytes at a time (`recv_cap`, `zig/src/serve.zig`), so while a
response is sent the buffer holds less than the receive that completed its
request; a buffer near `inCap` waits with at most the interim response.

**The adapter's state** (`Conn.State.parser`) is retained only while a
request is incomplete: `Conn` keeps it while reading and while sending the
interim response, and resets it to `init` once a request is consumed, so it
never coexists with a final response. `Conn` is generic over the adapter and
does not bound it; the hand-written parser keeps no state. H1's
(`H1Adapter.Parser`) is bounded from the limits of `H1Adapter.config`, part
by part, in the same blocks (from Std.Http's source at the toolchain; each
part is a definition in `Test.lean`, "The H1 adapter's retained state"):

- the machine's input, a copy of the buffer's bytes not yet consumed,
  compacted and appended to as receives arrive: at most `inCap` bytes with
  capacity at most twice, a block of at most 40,960, and a 24-byte iterator;
- the body pulled so far, appended chunk by chunk: under `maxBodyBytes`, a
  block of at most 20,480;
- the request-target, parsed into path segments and query parameters and
  kept in the message head until the request completes: at most 557,224.
  H1 maps every count limit of the target, `maxPathSegments` and
  `maxQueryParams` included, to `maxUriLength`, here 8,192
  (`requestTargetConfig` in `Std/Http/Protocol/H1/Parser.lean`, whose
  comment gives the reason: a component limit lower than the whole target's
  would reject with 400 a target that RFC 9112 would answer with 414), so a
  target may hold an element per byte. Every element (a path segment, a
  query parameter, a part of an absolute-form target) takes at least one
  byte of the target and at most 48 bytes of blocks per byte it takes; the
  costliest is the empty query parameter `&`, a 24-byte pair and a 24-byte
  empty `ByteArray` (an empty segment `/` takes 24). The arrays of segments
  and parameters, with at most 8,192 elements together and capacity at most
  twice their size (`lean_copy_expand_array`), take at most 163,880, and the
  target's own constructors 128: 48 × 8,192 + 163,880 + 128;
- the header fields: at most `maxHeaders` = 100 pairs of a name and a value
  string, whose bytes total at most `maxHeadBytes`: at most 34,076;
- the constructors of the parser, machine, reader, writer and head: at most
  1,024.

In all at most 653,788 bytes (638.5 KiB). What a parse allocates and drops
within a step (the target's split into strings, a field line) is per loop,
not per connection (above). `lsrv-test` checks each part against the blocks
the state actually holds (`test/retained.c` walks the state's objects and
adds `mi_usable_size` of each block, a shared one once, the persistent
initial state not at all) in every incomplete state of requests that drive
each part to its largest, fed whole and in pieces of 7 and 1,460 bytes; the
largest is 484,960 bytes, with a request line whose target is 8,176 empty
query parameters, the most the line allows (H1 keeps the target from the
end of the line, before any field). The arithmetic depends on the runtime (object
layouts, array growth, mimalloc's block sizes): that check is what keeps it
true across toolchain updates. It bounds live blocks; how much is resident,
and how much more freed blocks keep resident, `bench/boundary` measures.

**Measured** (`bench/boundary`, resident set growth per connection with
the H1 fixture, M1, 2026-11-17; from 1,000 connections against the idle
server for the first, otherwise from half to all of the connections, which
leaves out the fixed component). These are measurements, not bounds, and
they check no bound except the last, against the 110 KiB derived above
plus an allowance of 2 KiB for the small objects and the allocators'
metadata, which is not derived (`sendingBound`):

| each connection holds | connections | KiB per connection |
|---|---:|---:|
| an 8,000-byte head, after `100 Continue` | 1,000 | 52.0 to 52.1 |
| a head of 100 short fields, after `100 Continue` | 400 | 49.7 to 49.8 |
| all but one byte of an 8,192-byte body | 400 | 73.0 to 73.2 |
| a head of 97 fields of 72-byte values and all but one body byte, received 7 bytes at a time (`--chunk 7`) | 100 | 76.2 to 77.4 |
| an incomplete request after 50 pipelined ones | 400 | 31.4 to 32.1 |
| a head whose request-target has 4,000 path segments | 400 | 207.8 to 208.0 |
| a head whose request-target has 4,000 query parameters | 400 | 301.8 to 301.9 |
| a request line whose target has 8,176 empty query parameters, the most it allows, after a complete request | 400 | 500.7 to 501.0 |
| a 60,121-byte response being sent, with a pipelined tail buffered | 100 | 90.6 |

(Four runs each, 2026-11-17; earlier runs of the first and last rows gave
52.0 and 90.6 to 90.9.) For the 8,176 parameters, the adapter's state
holds 484,960 bytes (473.6 KiB) of live blocks (`lsrv-test`), besides the
connection's 20 KiB and its buffer; with the hand-written parser, which
keeps no state, the same connections grew the resident set by 41.6 KiB each.
The interim response shows that a connection
holds its head; for a body or a request line, lsof shows that the server has taken every byte
from its sockets, which does not exclude a receive not yet handed to Lean
(`awaitRead`). At 4,096 connections, connections holding the request line with
8,176 query parameters would take about 2.0 GiB resident.

The last scenario: connections whose client writes 8,192 bytes at once (100
pipelined GETs of the fixture's largest response, then an unfinished
request) and never reads, measured with either parser from 50 to 100 such
connections (from none to 100 it also counts an apparent fixed component of
about 500 KiB; more connections made macOS deny network memory for the
stalled responses the kernel holds). The socket queues, read with lsof,
show before each measurement that the server has read all 8,192 bytes and
after it that it has not sent all the responses; from that, each connection
was sending a whole response with at least 7,300 bytes buffered, unless its
bytes arrived in two receives and Lean had not yet been handed the second at
the measurement, which the queues cannot exclude (the scenario's comment).
Matched snapshots of the server's allocators at its two measurements
(`bench/boundary -memsnap DIR`: `vmmap -summary` and `heap -s`; nine runs,
five with H1 and four with the hand-written parser, 90.6 to 91.5 KiB per
added connection with the snapshots taken) split the growth per added
connection by region category, within these ranges in every run:

- the malloc zone, which holds the loop's connections, 21.1 KiB resident:
  one 20,480-byte block per connection (`heap -s` shows 50 more 20 KiB
  blocks per 50 connections, and no other block size grew but 512 bytes),
  13 more 512-byte blocks per 50 connections whose owner the snapshots do
  not show (0.1 KiB), and 1.0 KiB resident beyond the bytes allocated;
- the region vmmap names IOAccelerator, VM tag 100, which is the tag the
  toolchain's mimalloc gives its mappings by default (`mi_option_os_tag`),
  so most likely Lean's objects: 69.4 to 70.4 KiB, against 72 to 74 KiB of
  blocks allocated for the buffer (7,300 to 8,191 bytes: an 8,192 or
  10,240-byte block) and the response (a 65,536-byte block whose last 5.2
  KiB are never written);
- no other region category more than 0.8 KiB.

So the growth is consistent with the blocks allocated; it does not attribute
it, since the snapshots are aggregates: a region total cannot tell
which objects are live, nor separate untouched pages of a block,
still-resident pages of freed blocks (such as the initial `inCap` buffer)
and Lean's small per-connection objects. The snapshots are taken one after
the other, just before the resident set sample, not at one instant, and the
inspection may perturb the process; the resident set per connection with
and without them overlaps (90.6 to 91.5 against 90.6 to 90.9). macOS only:
elsewhere the scenario is skipped, as are those that read the socket
queues.

## Fragmented requests (decision D1)

The adapter keeps its parse state between receives (`Server.Adapter`), so
H1 feeds its machine only the bytes that arrived since the last receive.
For an adapter that keeps the law `Adapter.Incremental`, `Conn.step_fed`
proves that the adapter answers every buffer as from its initial state,
whatever the events in between (an interim `100 Continue`, pipelined
requests), and `Conn.fragments` that receives each answered with another
receive end as their concatenation received at once;
H1's functions are `partial`, so `lsrv-test` checks that law for both
adapters (pieces of 1, 2, 3, 7 and 64 bytes, each waiting prefix asked
again as after `100 Continue`, every two-piece split of the smaller
requests, and the corpus). The hand-written parser keeps no state
and parses the whole buffer again on every receive. `lsrv-bench` feeds
requests to `Conn.step` in receives of k bytes (M1, 2026-11-17; CPU time
per request):

| request | bytes | k | receives | hand-written ms | H1 ms |
|---|---:|---:|---:|---:|---:|
| browser GET, 16 headers | 789 | 1 | 789 | 1.2 | 0.5 |
| browser GET, 16 headers | 789 | 1,460 | 1 | 0.0 | 0.0 |
| largest head | 8,196 | 1 | 8,196 | 116 | 182 |
| largest head | 8,196 | 7 | 1,171 | 17 | 27 |
| largest head | 8,196 | 64 | 129 | 2.0 | 3.2 |
| largest request | 16,388 | 1 | 16,388 | 758 | 195 |
| largest request | 16,388 | 7 | 2,342 | 109 | 28 |
| largest request | 16,388 | 64 | 257 | 12 | 3.3 |
| largest request | 16,388 | 1,460 | 12 | 0.6 | 0.4 |

What remains quadratic with H1 is a single long line: the toolchain's H1
parses a line that has not ended again from its start on every call
(`parseWith` leaves its input where it was when the line is incomplete), so
the largest head, almost all of it one header line, still costs 182 ms of CPU in
one-byte receives, bounded by `maxHeadBytes`. Not worked around here (D1: no
local workaround of the parser). The memory bounds above hold for any
split, since the buffer never exceeds `inCap`.

## Running

Run everything (macOS or Linux; needs the Lean toolchain from
`lean-toolchain`, Zig 0.17, Go and PostgreSQL with `pg_config`, which
also provides libpq; Homebrew `postgresql@18`):

```sh
./bench.sh
```

It builds all parts, runs the Lean tests (`lsrv-test`: both adapters on the
same requests, limits at their exact boundaries, Host and target
validation, `100-continue`, the response checks, and connections through
`Conn.step`, and that `zig/src/pg.c`'s result bound equals
`Query.maxResultBytes`), the module boundary check (`lsrv-arch`), a check that `zig/`
built for x86_64 Linux at the Lean toolchain's glibc references no libc
symbol that glibc lacks (and that the same build for glibc 2.41 does), the parser comparison
(`lsrv-compare`), the boundary tests and the
end-to-end checks (the last two against both parsers), then measures both
parsers' cost per request in isolation (`lsrv-bench`, which prints each row
as it is measured) and each
server at 1, 64 and 256 connections for 10 s, printing requests per second,
latency percentiles and server CPU time per request; the Lean servers must
then stop gracefully on SIGTERM. Then it creates a private PostgreSQL
cluster under its temporary directory (a Unix socket there, no TCP
listener; any other PostgreSQL on the machine is not touched), runs
`bench/dbcheck` and measures `lsrv-db` against `bench/pgserver`. Any failure stops it with a nonzero status,
and every server it started is stopped on exit. A server that stops
answering keeps it from ending; that is a failure to trace, never a result.

`./bench.sh` first runs `./check.sh`: every build, test and check above,
without the measurements (and so without `lsrv-bench`, `dusty-hello`,
`bench/load`, `bench/goserver` and `bench/pgserver`). What `lsrv-bench`
measures is also checked, in `lsrv-test`: both parsers consume the same
bytes of each corpus sequence, and each fragmented request is answered after
its last receive as in one receive (item 6zs4mr). Run `./check.sh` on its own while
editing; the whole `./bench.sh`, measurements included, is the gate for
integrating a change (item cxhvkb). Both scripts share their helpers and the
private cluster's setup through `bench/lib.sh`; `bench.sh` measures on a
fresh cluster after `check.sh`'s has been removed.

`check.sh` runs `zig build test` against the one libpq `pg_config` names.
`./libpq-lines.sh PGSRC` runs it against every libpq line the pool supports
("Modules", `zig/`: 14.6, 15.1, or 16 and later): the lowest supported release
and the newest release of each line from 14 up, built from the release tags
of `PGSRC`, a git checkout of PostgreSQL
(`git clone https://git.postgresql.org/git/postgresql.git`), into a cache
outside the repository (`$LIBPQ_CACHE`, default
`~/.cache/lean-zio-http/libpq`). It checks that each run loaded the libpq it
built (`pg_glue_test` prints the file and the version it loaded) and prints
one line per release. It is opt-in, not part of `check.sh` (item oruxe4):
run it for every change to the PostgreSQL glue and at libpq updates. On
the M1 (2026-11-17, 10 releases from 14.6 to 18.7) the first run, building
every libpq, took 269 s, and a run on a warm cache 5 s; the cache holds
81 MB, the checkout 596 MB.

`bench/boundary` starts the fixture server (`lsrv-fixture`, and
`lsrv-fixture-hand` with `-no-continue`) with the test settings and checks:
exact 60,001-byte responses through 7-byte operations, split and pipelined
requests, injected failures, 2,000 connections closed or reset at different
points, `100-continue` and a response over the bound, the graceful shutdown
with a response in flight and an idle and a partial connection, admission at
`--max-conns 2`, the two crash points, and the memory per connection
(measured; checked against a bound only while a response is sent, README
"Memory"); every
accepted connection must be freed exactly once and the server must stop
with status 0.

`bench/dbcheck` starts `lsrv-db` with one loop for each test and checks,
without assumptions on elapsed time (a query waits on an advisory lock the
test holds; `pg_stat_activity` tells the test it is waiting): results, a
missing row and two chained queries; a slow query does not delay the loop's
other connections (a request with no query, and a query on the second
slot); pool exhaustion (one slot: 20 queries queue behind a waiting one,
which the server's `query` trace lines confirm, PostgreSQL sees one
connection, all complete once the lock is released); a
restart (`pg_ctl restart -m fast` with a query in flight, its lock held by a
prepared transaction so it cannot finish first: 503, then, once the
`pg closed` trace lines show both old sessions ended, 200 on fresh
connections on both slots); errors on one slot (a query that cannot be
prepared, a cached statement failing when executed, `BEGIN` leaving a
transaction open: each 500 with its SQLSTATE, and the slot answers the next
query); the database stopped (503, 200 once started); and SIGTERM with a
query waiting (once the `stop` trace line shows the shutdown started, the
lock is released: the query is answered, then `stopped` and status 0).

Reading the numbers: the load generator runs on the same machine, so at 64
and more connections it is the limit; compare the 1-connection rows and the
CPU per request. The servers differ in features and limits (above), and
closed-loop latency hides queueing under overload. The numbers exclude
connection setup: `bench/load` opens every connection with one warm-up
request before the clock starts (item vma67w, at the end of "The dusty
failure at 256 connections" below); only the server CPU per request still
includes those warm-up requests, `bench.sh` samples it around the whole run,
at most 256 requests against hundreds of thousands. Acceptance runs belong on
Linux with HttpArena's tooling (item 53rwgc).

## `Std.Http.Protocol.H1` compared with the hand-written parser (item 7bccgi)

Toolchain leanprover/lean4 nightly-2026-11-14 (`lean-toolchain`); paths
below are under its `src/lean/Std/Http/`. Numbers from one `bench.sh` run on
the M1 (2026-11-16). Written before the module split: `Http.lean` is now
`Server/HandParser.lean`, `H1Adapter.lean` is `Server/H1Adapter.lean`,
`lsrv-h1` is now `lsrv` and the old `lsrv` is `lsrv-hand`; the adapter has
since started answering `Expect: 100-continue` (above).

### Does H1 run without Std.Async and fit `Conn.step`?

Yes. `Protocol/H1.lean` and its modules import no `Std.Async`
(`Protocol/H1.lean:9-19`; `Protocol/H1/Redirect.lean:24`: "This module never
touches `IO` or `Async`"); only the server around it does
(`Server/Connection.lean:9-10` import `Std.Async.TCP` and
`Std.Async.ContextAsync`). The machine is pure: `feed` (`H1.lean:922`) appends
bytes, `processRead` (1919) parses the start line and headers, `pullBody`
(1981) yields the body, `canContinue` (1230) answers `Expect: 100-continue`.
A server-side machine never drains the body itself (1861-1867: "Server-side
(`.receiving`) keeps the existing semantics so handlers can observe the body
stream explicitly"), so the adapter calls `pullBody` until the body is
complete. Each `handle` call runs a fresh machine over the connection's buffer,
as `Http.parse` re-parses from the start, and answers `Conn.step`'s `Reply`
from the reader's state: `.complete` with the bytes consumed
(`buf.size - input.remainingBytes`), a failure with the status H1's own server
gives it (a copy of the private `errorResponseStatus`, 1502), anything else
need-more. `Conn.lean` and the loop are unchanged.

What H1 accepts and rejects that matters here: limits are separate for the
start line (`maxStartLineLength`, 414 at 1750; `maxUriLength`,
`Protocol/H1/Parser.lean:248`), the header block (`maxHeaders`,
`maxHeaderBytes`, 431 at 1821-1830) and each name and value (`maxHeaderNameLength`
256, `maxHeaderValueLength`, 400); there is no limit on the whole head as in
`Http.parse`. Methods must be registered IANA names, case-sensitive, else 501
(`Parser.lean:235`); HTTP/1.x with x > 1 is read as 1.1 and other versions get
505 (`Parser.lean:303`, `H1.lean:1759`); the target must be valid URI syntax
and suit the method (CONNECT only authority-form, `*` only with OPTIONS,
`H1.lean:250-262`); exactly one Host, empty or a valid host, matching a
CONNECT authority (294-312); conflicting Content-Length, or Transfer-Encoding
with Content-Length, or chunked in HTTP/1.0, is 400; chunked is decoded, other
codings get 501 (317-345). Up to 8 empty lines before the request line are
skipped (`Parser.lean:127`). The adapter's choices: the hand-written limits
mapped onto H1's (`H1Adapter.config`; `maxHeaderValueLength` is the loop's
buffer so that a complete over-limit head gets 431 as `bench/check` expects),
a chunked body refused with 501 once its head is read, the spike's
contract, although H1 could decode it; and `Expect: 100-continue` handled as
`Http.handle` handles it, by waiting for the body without an interim 100
response (RFC 9110 §10.1.1 asks for a 100 or a final response; neither
parser's handler sends one yet, see the list above).

### Cost per request

`lsrv-bench`: the same bytes through `Http.parse` and `H1Adapter.parse`, the
median of 5 runs after a warm-up, and allocations as the change in
`IO.getNumHeartbeats`, which counts small-object allocations only
(`Init/System/IO.lean:590-595`); `handle` adds building the response.

| request | bytes | hand-written ns | allocs | H1 ns | allocs | H1 / hand-written |
|---|---:|---:|---:|---:|---:|---:|
| GET | 27 | 404 | 24 | 2,143 | 128 | 5.3× |
| HEAD | 28 | 411 | 24 | 2,159 | 128 | 5.3× |
| POST then pipelined GET | 79 | 678 | 39 | 3,540 | 208 | 5.2× |
| browser GET, 16 headers | 789 | 8,366 | 642 | 38,088 | 2,183 | 4.6× |
| 100 headers (the limit) | 909 | 15,152 | 1,104 | 83,662 | 5,258 | 5.5× |
| largest head (8,192 B) | 8,196 | 75,039 | 8,197 | 279,916 | 16,500 | 3.7× |
| largest request (16,388 B) | 16,388 | 76,746 | 8,195 | 268,724 | 16,543 | 3.5× |

The hand-written parser allocates about one small object per head byte (its
`while` loops in `Id.run do`), so both columns have room to fall.

Under load (`bench.sh`, 10 s per run, load generator on the same machine):

| server | c=1 req/s | CPU µs/req | c=64 req/s | CPU µs/req | c=256 req/s | CPU µs/req |
|---|---:|---:|---:|---:|---:|---:|
| lean-zio (hand-written) | 20,465 | 17 | 76,496 | 25 | 77,703 | 23 |
| lean-h1 | 19,136 | 22 | 77,324 | 29 | 83,606 | 28 |
| go | 16,242 | 43 | 80,633 | 41 | 82,357 | 38 |
| dusty | 18,172 | 20 | 67,210 | 37 | 79,898 | 37 |

H1 costs about 5 µs more CPU per request (+20 to +30 %) and 6 % of the
1-connection throughput (a second run: 16, 25, 22 against 21, 27, 26 µs and
20,794 against 19,093 req/s); at 64 and 256 connections the load generator is the
limit. `lean-h1` still uses less CPU per request than Go and dusty at 64 and
256 connections, and about as much as dusty at one.

### Where the verdicts differ

`lsrv-compare` (seed fixed in the source). Agreement: 2,000 generated valid
requests (random methods, targets, header order and case, OWS, Content-Length
bodies, Connection values, pipelining) give both parsers need-more on every
proper prefix and the same method, target, Content-Length, close decision and
bytes consumed; H1's Host value equals the one sent (the hand-written parser
does not extract it). Limits at their exact boundaries agree where the two
count the same thing (100 and 101 fields, a body of 8,192 and 8,193 bytes) and
differ where they do not: a head of 8,193 bytes is 431 for the hand-written
parser and accepted by H1, whose start line and header block each have 8,192
bytes; a request line of 8,193 bytes is 431 and 414 (RFC 9112 §3: a server
"SHOULD respond with a 414"; both close).

Malformed input: 61 templates on 40 requests each (2,440, of which 732
differ) and 30,000 single-byte edits (2,732 differ). Every disagreement,
grouped (an edit at a field's CRLF is counted with the value it ends):

| input | hand-written | H1 | cases | what decides it |
|---|---|---|---:|---|
| Host value not a valid host (`a b`, `a@b`, `a:99999`, edited bytes, `::`) | ok | 400 | 971 | RFC 9112 §3.2: a server MUST answer 400 to a Host field with an invalid value. H1 conforms; the hand-written parser does not check Host syntax. |
| bare CR or bare LF in the head (CR or LF deleted, a byte inserted between them) | need-more until the buffer is full, then close without a response | 400 | 677 | RFC 9112 §2.2: a bare CR MUST be treated as invalid or replaced by SP; a lone LF MAY be accepted. Both conform; H1 answers at once. |
| method not a registered name (`BREW`, `get`, edited bytes) | ok (404), or 400 when the edit puts SP in it | 501 | 477 | RFC 9110 §9.1: methods are case-sensitive; an unrecognized one SHOULD get 501. H1 follows the SHOULD; the hand-written parser accepts any token and routes it to 404. |
| target not URI syntax (`/a#f`, `/a%zz`, `a`, non-ASCII byte, `/` deleted, edited bytes) | ok | 400 | 503 | RFC 9112 §3.2 (origin-form is an absolute path, no fragment) and §3: an invalid request line SHOULD get 400. H1 follows it. |
| `GET *`, `CONNECT a:443` with another Host | ok | 400 | 68 | RFC 9112 §3.2.4 (`*` only for OPTIONS), §3.2.3 and RFC 9110 §9.3.6 (authority-form only for CONNECT). H1 conforms. |
| header name over 256 bytes | ok | 400 | 40 | RFC 9110 §5.4: a server MAY reject a field it finds too large with a 4xx (431, RFC 6585 §5). Both conform; H1's `maxHeaderNameLength` is fixed at 256 here. |
| Connection value not a list of tokens (`close;x`, `% keep-alive`, `,` deleted) | keep alive unless it finds `close` | close | 350 | RFC 9110 §7.6.1 defines no handling of an invalid value; closing is the safer reading. |
| Transfer-Encoding with Content-Length, or not ending in `chunked`, or empty | 501 | 400 | 187 | RFC 9112 §6.1: TE with CL "ought to be handled as an error" and the connection closed; a coding the server does not understand SHOULD get 501. H1's 400 for codings that cannot frame the body follows §6.3 (3); either status is defensible. |
| Content-Length `99999999999` | 400 | 413 | 22 | RFC 9110 §8.6 (a valid number) and §15.5.14: a body over the limit gets 413; the hand-written parser rejects more than 10 digits as invalid. Both close. |
| HTTP/0.9, HTTP/2.0, HTTP/0.1, HTTP/9.0 | 400 | 505 | 86 | RFC 9110 §15.6.6: 505 for an unsupported major version. H1 is more precise. |
| HTTP/1.2, HTTP/1.9 | 400 | ok, as 1.1 | 41 | RFC 9110 §6.2: a recipient SHOULD process a higher minor version as the highest it supports. H1 conforms. |
| empty line before the request line | 400 | ok | 35 | RFC 9112 §2.2: a server SHOULD ignore at least one empty line before the request line. H1 conforms. |
| no SP between target and version (`GET /xHTTP/1.1`, CR or DEL in its place) | 400 | need-more | 7 | RFC 9112 §3: an invalid request line SHOULD get 400. H1 reads the target up to the next SP (`Parser.lean:249`), so it waits for more bytes and answers 414 only after 8,192; the hand-written parser conforms. |

In short, H1 is stricter and closer to RFC 9112 and 9110 in every group but
the last, where it is slower to reject a malformed request line. Neither
parser accepted anything the other framed differently: no request was
consumed with a different length or body by the two.

### Proposal for D1 (decided: D1 in the decision record)

Options:

1. Adopt H1 behind `H1Adapter` and delete `Http.parse`. Cost: about 5 µs of
   CPU per request in this route (1.7 µs of it measured in isolation for a
   plain GET), still below Go and dusty under load; gain: Host validation
   (an RFC MUST the hand-written parser misses), immediate 400 on bare CR,
   target syntax, 501 and 505 where they apply, and chunked bodies available
   when the spike wants them.
2. Option 1, and offer upstream (leanprover/lean4) a fix that ends the
   request-target at CR, LF or a control byte, and an issue with
   `lsrv-bench`'s numbers about its allocations (2 to 5 times the
   hand-written parser's small objects per request; header values become
   `String`s). Until upstream answers the code stays as it is,
   with no local workaround.
3. Keep the hand-written parser and add Host syntax checks and the bare-CR
   rejection it lacks: about a fifth of H1's parse time in isolation, 4 to
   5 µs (15 to 25 %) less server CPU per request under load.

Recommendation: option 2. H1's extra cost is not material against the
servers the spike compares with, its verdicts are the more correct ones, and
it is maintained with the toolchain; the one place where it is worse (a
malformed request line held until 8 KiB) is better fixed upstream than
around it.

## The dusty failure at 256 connections (item 2l6rcv)

Cause: on this machine (the M1, macOS) a listening socket holds at most 128
connections the server has not accepted yet, and in the experiment below the
connections past that were reset. The load generator dials all its
connections at once, so at 256 and 512 connections a server that does not
accept fast enough in the first milliseconds loses some to a reset, and the
run fails. It is not specific to dusty: Go fails the same way. The evidence
below is indirect (outcomes and timing, no packet trace), but every failure
seen matches it and none falls outside it.

Evidence (2026-11-16, diagnostic scripts outside the repository, not tests):

- Limit: `sysctl kern.ipc.somaxconn` is 128; dusty asks for that backlog
  (`src/server.zig:576-589` and `Listener.kernel_backlog` in
  `src/config.zig`, dusty 96e117f), Go's `net.Listen` asks for it too, and the
  Lean loop asks for 4,096 (`zig/src/serve.zig:472`). A Go program that
  listens with backlog 128, or with 4,096 through `listen(2)`, never accepts,
  and dials N connections at once that each send a byte and read: for N = 128
  all 128 wait in the queue; for N = 129, 160, 192, 256 and 512, exactly 128
  wait and the other 1, 32, 64, 128 and 384 get `read: connection reset by
  peer`. So macOS caps the backlog at 128 here, whatever is asked, and the
  connections past it fail with a reset (no packet trace shows how).
- Reproduction: 30 iterations of a fresh server, then `bench/load` at 64,
  256 and 512 connections for 3 s each. Failed runs out of 30:

  | server | c=64 | c=256 | c=512 |
  |---|---:|---:|---:|
  | dusty (3 accept loops, its default for 10 CPUs) | 0 | 7 | 19 |
  | dusty with `.acceptors = 8` | 0 | 5 | 13 |
  | go | 0 | 3 | 11 |
  | lean-zio (`lsrv 8`) | 0 | 0 | 0 |

  All 58 failed runs above ended with `read: connection reset by peer`,
  the form the queue experiment gives, or `connect: connection reset by
  peer`, which it did not give; that form was not traced further, but it
  came in the same runs and, in the timing runs below, in the same first
  milliseconds. dusty logs `Connection error:
  error.SocketUnconnected` (ENOTCONN) 200 times in its 30 iterations, fewer
  than its failed connections and none in some failing iterations: consistent
  with connections reset before dusty used them, not a cause of the
  failures.
- Timing: with the generator changed (outside the repository) to note when
  each connection failed, 12 runs of dusty at 512 connections for 2 s had
  their last failure 13 to 39 ms after the start, none later: the failures
  happened while the connections opened. This was measured at 512
  connections only.
- Not checked: `netstat -s -p tcp` prints 0 for every counter here, so the
  kernel's listen queue overflow counter could not confirm the drops.

What it means for the numbers: a run that passed had no reset, so these
resets did not bias dusty's or Go's numbers from runs that passed (the
caveats under "Reading the numbers" above still apply to them). `bench.sh`
failed at 256 connections now and then for this reason (in the loop above,
about one run in four for dusty and one in ten for Go): of its two runs for
this item, the first passed and the second failed at dusty c=256 with
`read: connection reset by peer` on 4 connections. Why Lean's loop drains
the queue fast enough and dusty's does not was not traced: more accept loops
in dusty did not remove the failures.

The fix (item vma67w): `bench/load` now opens its connections before the
measurement. Each connection, with its own transport so that no other
request takes it over, sends one warm-up request and waits for its response,
the event that shows the server accepted it; at most 128 connections await
that first response at a time, and the clock starts once every connection
has answered. No delays or retries are involved, and the measured numbers
exclude connection setup. With it, the same 30-iteration loop (fresh server,
then 256 and 512 connections for 3 s; 2026-11-16) failed 0 of 30 runs at
each count for dusty (3 accept loops) and for Go, and a c=512 run held 512
established connections on both the generator's and Go's side.
