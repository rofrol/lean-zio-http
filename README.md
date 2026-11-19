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
| `App.Arena` | HttpArena's HTTP/1.1 endpoints ("HttpArena on the VPS") | `Server.Handler` |
| `Main`, `Fixture`, `MainDb`, `MainArena` | composition roots `lsrv`, `lsrv-fixture`, `lsrv-db`, `lsrv-arena`: H1 and one application | `Server.Transport`, `Server.H1Adapter`, `App.*` |
| `MainHand`, `FixtureHand` | `lsrv-hand`, `lsrv-fixture-hand`: the same with the hand-written parser | `Server.Transport`, `Server.HandParser`, `App.*` |
| `Test`, `Bench`, `Compare`, `Corpus`, `Arch` | tests and measurements | anything |
| `docs.upstream.*` | reproducers for the drafts of upstream reports in `docs/upstream/`, run with `lean --run`, not built by Lake | `Std.Http.Protocol.H1` |

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
  connection's completion from its own callback relies on zio's documented
  contract (pinned 53ed3c377317, `src/ev/completion.zig`, `Completion.callback`,
  https://github.com/lalinsky/zio/pull/929): "The completion is already dead
  when it runs, and for a completion with neither `rearm` nor a group or queue
  owner the loop does not touch it after the callback returns. The callback
  may therefore free it, or reuse its memory for the next operation, of the
  same or another type, and `add` it again." The transport sets no `rearm`
  and uses no zio group or queue (`zig/src/serve.zig`, `Op`). The loops run
  on kqueue on macOS and, on Linux, on the backend the build names: epoll
  (the default) or io_uring, chosen by `LSRV_LINUX_BACKEND` for `lake build`
  (`-Dlinux-backend` of `zig/build.zig`; item wi7efy, which superseded
  mzqamr's epoll-only pin). `zig/src/serve.zig` does not compile on zio's
  `.linux` backend, which picks one at run time. The transport submits
  sends, and decides when to poll beside one, the same way on all three
  (the order in which zio runs other operations still differs between
  readiness and completion backends): it tries each send itself (`send`
  with `MSG_DONTWAIT`) and reports a result to Lean on the loop's next
  turn (a per-loop ready
  list woken by a zio `Async`), and hands zio only a send that returned
  EAGAIN, which zio then waits on; so a send is parked, and the readiness
  poll starts beside it (section "Deadlines"), only after the kernel said
  EAGAIN, whatever the backend. zio's io_uring backend would otherwise queue
  every send untried, and each would look parked. The deployed server runs
  on epoll: item dtlin3's measurements on its host after the accept fix
  (section "HttpArena on the VPS") resolve no difference in throughput or
  CPU between the two backends; io_uring's p99 there is lower in two
  profiles of four.
  Each loop
  also owns a PostgreSQL pool (`src/pg.zig`, section "PostgreSQL"). The
  library needs libpq's headers (`-Dpq-include`) and the servers link
  `-lpq`: libpq 17 or later (pipeline mode, and its chunked-rows mode,
  `PQsetChunkedRowsMode`; decided 2026-11-17, item 4lmjda); `zig/` does not
  compile against older headers, and a server with `--pg` exits with
  status 1 at startup when the libpq it runs is older.
- Command line: `lsrv [THREADS] [--port N] [--max-conns N] [--pg CONNINFO]
  [--pg-conns N] [--idle-ms N] [--head-ms N] [--body-ms N] [--write-ms N]
  [--pg-query-ms N] [--pg-query-max-ms N] [--pg-connect-ms N]
  [--pg-statement-ms N] [--drain-ms N]` (`--pg-conns`, default 4, is per
  loop; without `--pg` no pool is made and every query fails with `08006`;
  the four connection budgets, in milliseconds, are in "Deadlines" below,
  the four database budgets in section "PostgreSQL", "Deadlines", the
  drain in "Shutdown"), then the test
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
- `dusty-hello/`: the same route on dusty, the HTTP library on zio. Its
  `build.zig` gives dusty's module the real zio in place of dusty's stub
  `zio` import, the setup dusty 0.6.0 documents for applications on the zio
  runtime, so dusty's deadlines use zio.AutoCancel instead of its portable
  watchdog, a second task per connection (`src/deadline.zig`; decided
  2026-11-17, item im7c5q). A Debug build shows the switch:
  `deadline.Watch.wait` is gone and `AutoCancel.setClock` is linked. In one
  `./bench.sh` run each on the M1, the stub before and the real zio after,
  dusty's throughput changed by 2% or less at each concurrency, while Go,
  unchanged, moved by up to 6% between the same two runs; one run each
  establishes no repeatable effect either way:

  | dusty | c=1 req/s | c=64 req/s | c=256 req/s | CPU µs/req (1/64/256) |
  |---|---|---|---|---|
  | stub (watchdog) | 21,132 | 80,748 | 84,493 | 18 / 40 / 36 |
  | real zio (AutoCancel) | 21,545 | 79,414 | 83,883 | 16 / 39 / 34 |
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
  after the response reports it). A send the kernel takes (in whole or
  in part) at the loop's first try starts no poll: the loop goes on at
  once with the response's next send, which gets the poll if it waits, or with the receive that sees
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
  is not reported. The shutdown has its own bound, the drain ("Shutdown").
- **Admission.** At most `--max-conns` connections (default 4,096) are open
  process-wide; the rest wait in the kernel's listen queue. A loop arms its
  accept only with a free slot, and an accepted connection keeps the slot
  until its close; a loop that finds none pauses its acceptor and re-arms it
  when one of its connections closes (the liveness argument is next to
  `slots_used` in `zig/src/serve.zig`). The accept's callback then takes
  further pending connections itself with `accept(2)`, each with a slot
  reserved first, up to 64 in one callback with the one its completion
  returned, and stops earlier at `EAGAIN` or when no slot is free; it then
  re-arms (or pauses) once. zio runs the completion of an accept added from
  its own callback only on the loop's next turn, so with one connection per
  callback a loop admitted one per turn (item sakmfp; "The over-5 s tail",
  below). The bound keeps one callback's work finite, so the loop's
  established connections and the other loop get their turn while a
  backlog is taken. At startup the soft `RLIMIT_NOFILE`
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
  connection closes, and a query in flight or waiting for a pool slot at
  most for its completion budget (section "PostgreSQL", "Deadlines"). The
  drain bounds the whole: `--drain-ms` (default 10,000, from 1 to below
  2^32; decided 2026-11-17, item ytzycm) from a loop's stop, armed only
  while the loop has connections open and taken off when the last closes.
  When it ends, the pool answers every query (`error 57014` for one not
  yet sent, `abandoned 57014` for one running, whose session it closes
  without PQcancel) and answers later ones at once, unsent; a send in
  flight is canceled, a handler that answers after that end gets its
  connection closed instead of a response, and every connection closes;
  no send starts after that end. So a loop's shutdown ends by the drain, except
  for a connect in flight that no query waits for, which ends by its own
  `--pg-connect-ms`.
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
  and the loop whose connection closed re-arm and take it. Taking a
  backlog (item sakmfp; clients on a Unix-domain socket, whose connect
  returns once the connection is queued, all connected before the loop is
  polled): connections pending when the accept's callback runs are all
  opened in that callback, within the batch, which then re-arms at
  `EAGAIN`; a larger backlog is opened at most a batch per turn while an
  established connection's byte is reported before the last is opened;
  when the slots run out the callback stops and admission pauses until a
  close releases one; a direct accept that fails (injected,
  `fail_accept_every`) gives its slot back and the callback goes on; and
  two loops started on a pending backlog take it up to the slots, both
  pause, and a released slot takes one more. (4) The loop
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
  (6) The drain: one that ends with a send waiting in the kernel cancels
  it, unreported, and closes the connection; every shutdown test's run
  returns only because the drain was taken off when the last connection
  closed. The pool's tests check its end (`Pool.abort`): the running query
  abandoned, the queued one unsent, both sessions closed, a later query
  answered at once.
  (7) Orderings delivered explicitly (item qgrnr3): which order a poll
  delivers a completion, its cancel and an expiry in depends on the backend,
  so these tests hold the real completions back from `serve.zig`'s callbacks
  until the loop has completed them, then hand them over in the order the
  test names (zio's `Completion.callback`: for a completion with neither
  `rearm` nor a group or queue owner, as all of the transport's are, the
  loop does not touch it after its callback returns). They control when
  `serve.zig`'s callbacks run, not the kernel's order. An expiry before its receive's
  completion closes, unreported, whether the cancel came too late (the
  bytes) or reached it (canceled); a receive before the expiry of the
  generation it ends is reported and that expiry is stale, released
  unreported; one within the period leaves the expiry current, and it
  closes. A receive completed before the shutdown's cancel is reported once;
  one the cancel reached is refused. A performed send (`.wrote`) queued in
  the ready list when the shutdown runs is not canceled: its turn, before
  any expiry or the drain's end, reports it once; in the test the send ends
  the response, the receive Lean then asks for is refused, and the
  connection closes once (item c5ca75). An expiry before a queued performed
  send (`.wrote`) closes, the send unreported; that send before the expiry
  is reported, and the expiry is stale when the send ended the response and
  current when it did not. Connections in the ready list that perform their
  next send during its turn are reported once in it and taken by the next
  turn, in order, also when one of them closed on an expiry before the
  turn. They do not assert which order a backend takes.
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
  must not deallocate statements (`DEALLOCATE`, `DISCARD ALL`). An
  execution of a cached statement that fails with `0A000` or `26000` fails
  that query with PostgreSQL's error, which is not resent, and the statement
  is forgotten: the text's next use prepares it again, under a name the
  connection never used. These two SQLSTATEs cover a statement gone stale
  (its result type changed after a schema change is `0A000`; one the server
  no longer has is `26000`) and other errors as well, since PostgreSQL
  documents nothing narrower; a good statement forgotten costs a fresh
  Prepare. Before that query is answered, the forgotten statement is closed
  on the server (a Close with its own Sync, one more round trip), so the
  server holds only the statements the connection caches; a connection
  whose Close fails, or that is lost during it, or whose query's deadline
  (or the shutdown drain) ends during it, is closed and the query answered
  with its own error, never replayed: its execution failed without effect,
  and only the statement's cleanup is uncertain, so it stays an `error`,
  not `abandoned 57014` (decided 2026-11-17, item ncvxfx).
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
  are received in chunks of 16 (libpq's chunked-rows mode; libpq hands a
  chunk over once it is full or the rows have ended) and each row is
  charged before it is built; at the row that crosses the bound the rows
  gathered are released, the query is answered `abandoned "54000"` once
  and its session is closed without reading the rest. So whether the statement took effect
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
  for any client that disconnects. A connect that fails (or reaches its
  deadline) while no connection of the pool is busy fails every query
  waiting at that moment, each once with `08006`; a query submitted later
  starts the next connect. While connections are busy, the queries waiting
  wait for them instead, each to its own deadline, and no connect starts
  until one of them gets a complete answer from the database (rows or
  PostgreSQL's error), which then serves the queue and lets a connect start
  again; when the last busy connection ends without such an answer (lost,
  expired, closed), the queue fails once with `08006`. So with the database down a loop has at most one connect
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
  write may commit, and the query is never sent again. One whose own
  answer is already known, with only the Close of a forgotten statement
  pending, is answered with that answer instead and its session closed the
  same way ("Statements"). A connect that ends
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
  write completion arriving after the slot went idle, output that collect
  queued (a Close) flushed before its results are awaited and a connection
  lost then delivering the query's answer, a session ended
  (COPY) with both polls outstanding, synchronous chains of 10,000
  failing queries (no slots, the database down) that stay iterative and
  let a receive ready on the same loop run before they end, each result
  delivered once, a query submitted while one waits for its turn queued
  behind it (and, after the drain's end, also one already waiting, run
  to their end at once),
  deadlines (an expiry in the queue unlinks only that query, a busy
  query's expiry closes its session without reading, which never serves
  again, a connect's deadline fails its waiters, a waiter's own earlier
  deadline, a timer callback after the completion changing nothing, a
  budget refused with `22023`, the drain's end), a lost connection before
  the query reached libpq (`error`) and after (`abandoned`: a failed send,
  flush or read), and a connect failing while a session is busy: the queue
  waits, no connect starts until that session's answer serves it, a
  connect's deadline follows the same rule, a session lost without an
  answer fails the queue once with `08006`, and a waiting query still ends
  at its own deadline.
  `src/pg_glue_test.c` runs `pg.c` and the real libpq against a fake
  PostgreSQL server on a Unix socket, each reply delivered whole, a message
  at a time and a byte at a time: command boundaries and Sync, errors,
  COPY in and out, a transaction left open, a connection lost mid-reply,
  cached statements forgotten (`0A000` from any routine and `26000` forget
  the statement and close it on the server before the answer, more than 64
  of them keep the session, a failed Close or a connection lost during it
  closes the session with the query's own error, a failed transaction closes
  it with no Close sent), and
  chunked collection, in chunks of 1, 2 and 16 rows: after every piece the
  rows held are exactly the whole chunks of the rows received (first use,
  cached and unnamed executions; two full chunks and a partial one),
  zero rows keep their columns, rows then an error answer the error, also
  after a full chunk, a result at exactly the bound is answered, and one
  byte over it, or a single field over it, ends the session once the
  chunk holding the row that crosses it arrives, in a full chunk or the
  last partial one (an oversized first row followed by five more: at that
  row with chunks of 1, at the second row with chunks of 2, at the end of
  the rows with chunks of 16, never later), answered `abandoned`
  (constructor 2), while a query with a NUL character is an `error 54000`
  (constructor 1) that sends nothing. A connection lost mid-reply is
  `abandoned 08006`, one whose EOF libpq saw before the next query refuses
  it unsent (`error 08006`), and every session's startup packet carries
  the startup options (`ekk_pg_options`: merged with the conninfo's or
  `PGOPTIONS`, refused for a service or for options ending in an unpaired
  backslash).
  `bench/dbcheck` checks the deadlines against the private cluster (a query
  expiring in flight and in the queue, `statement_timeout`, a connect to a
  listener that never answers, the shutdown's drain ending with a query
  running and one queued: both connections closed unanswered, the session
  closed without a cancel) and changes a column's type under a cached statement and back,
  and runs an `INSERT ... RETURNING` over the bound (abandoned with
  `54000`, the session closed, the insert wholly applied or not at all).
  A chain of queries that fail synchronously, each asked again from its
  error, runs inside the `submit` that started it for its first
  `chain_inline` (64) results; the rest goes on from later turns of the
  loop, which serves its other ready work in between, so a long chain may
  outlive the `submit` that started it (decided 2026-11-18, item rtkla3;
  `zig/src/pg.zig`, `chain_inline` and `Pool.yieldChain`). After the
  shutdown's drain has ended (`Pool.abort`) a chain runs to its end at
  once, since the drain then closes every connection.
- **Bounded only in part:** the pool gathers at most `Query.maxResultBytes`
  of a result, but libpq copies a chunk's rows into its own result before
  the pool sees them: the chunk that holds the row crossing the bound, up
  to 16 rows of any size, the 15 after it included. So one row larger than
  the bound costs its full size (in libpq's input buffer and again in its
  result) before the session is closed, and so may up to 15 rows after the
  row that crosses it, where single-row mode stopped at that row. libpq's
  input buffer also holds whatever more of the reply had arrived from the
  socket when the session closed (never parsed into rows), and keeps the
  size of the largest message a session received until the session is
  closed. The chunk size, 16 (`EKK_CHUNK_ROWS` in `zig/src/pg.c`), was
  chosen with `bench/rows.sh` against single-row mode (below).

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

One run's ratio does not show whether a change cost throughput: on the
shared M1 it spreads far wider than the distance to the goal (item fszibv,
2026-11-17, load average 11 to 63 on 10 cores). Fifteen interleaved rounds
of lean-db before item 3jnkx5's deadlines (7c89450), lean-db after them and
go-db, each round's lean-db divided by that round's go-db, gave:

| lean-db | c=1 lowest, median, highest | c=64 lowest, median, highest |
|---|---|---|
| before the deadlines | 0.99, 1.10, 2.14 | 0.47, 1.03, 1.44 |
| with the deadlines | 0.52, 1.08, 4.19 | 0.66, 1.02, 7.83 |

A single `bench.sh` run's 0.74 and 0.83 lie inside both spreads. CPU time
per request, which another process's load disturbs less, did not move in
the five rounds that measured it (rounds at a load average above 30 left
out): lean-db 36 to 39 µs at c=1 before and 37 to 39 after, 41 to 44 µs at
c=64 before and 40 to 44 after; PostgreSQL's backends 12 to 13 µs at c=1
and 18 to 20 µs at c=64 for both, so the `statement_timeout` the deadlines
put in every session's startup options shows no cost there either.

In the Linux container (`linux/Dockerfile` on OrbStack's arm64 VM, 10
vCPUs, kernel 7.2.12-orbstack, epoll), lean-db reaches only about half of
Go at one connection (item 7wvkwz, 2026-11-18, macOS host load average 4
to 26). The runs used the image and archive of "Running", with this in
place of `./bench.sh` in the container:

```sh
LIBRARY_PATH=$(pg_config --libdir) lake build lsrv-db &&
  (cd bench/load && go build -o load .) &&
  (cd bench/pgserver && go build -o server .) && bench/dbpairs.sh
```

`bench/dbpairs.sh` runs both servers side by side and alternates which goes
first in each pair, every sample ending after the same 100,000 requests
(`bench/load -n`; the per-request costs include the load's one warm-up
request). Ten pairs:

| c=1, 10 pairs | lowest to highest |
|---|---|
| lean-db / go-db requests per second | 0.49 to 0.56 (median 0.52) |
| p50 latency, lean-db; go-db | 90 to 102 µs; 40 to 41 µs |
| server CPU µs per request, lean-db; go-db | 34 to 37; 23 to 25 |
| voluntary context switches per request, lean-db; go-db | 1.81 to 1.90; 2.30 to 2.40 |
| involuntary ones, lean-db; go-db | 0.13 to 0.23; 1.06 to 1.09 |
| private cluster's CPU µs per request, lean-db; go-db | 19 to 21; 10 to 11 |

lean-db's own database path is not where the time goes; what the reply's
wait holds, PostgreSQL's work or the wake-up, these measurements do not
split. Over 20,000 requests under
`strace -f -c`, lean-db makes 9 system calls per request (4 `recvfrom`, one
of them the peek's re-armed receive failing with `EAGAIN`; 2 `sendto`;
3 `epoll_pwait2`; 5 `epoll_ctl` in all, so no registration per request) and
go-db 16 (3 `futex`, 1 `nanosleep`, 4 `epoll_pwait`, 5 `read`, 3 `write`);
PostgreSQL's backend makes the same 2 `recvfrom`, 1 `sendto` and 1
`epoll_pwait` per request for both. The sequence (`strace -f -tt`) shows the
loop sending the query and then waiting in `epoll_pwait2` with no other turn,
and libpq reading the reply with one `recvfrom`. A temporary timing patch of
`zig/src/pg.zig` (not kept) split lean-db's request at its median: 42 to
51 µs from the previous answer's delivery to the next query's send (the
client's turn, the loop's wake-up on the HTTP request, parsing and the
handler), 5 µs to send and flush the query, 34 to 36 µs waiting for the
reply (PostgreSQL and the loop's wake-up), 3 µs in libpq and `pg.c`, 7 µs
delivering the answer and sending the response. lean-db's own database path
is about 15 µs; the rest is two waits per request (the first also holds the
client's work, the second PostgreSQL's), each ending in a wake-up of the
loop's parked thread.

What the measurements fit, without proving it: in the VM, waking a thread
whose vCPU went idle costs tens of microseconds, and Go's runtime keeps
vCPUs from going idle by spinning its idle threads before they park (the
`futex`, `nanosleep` and involuntary switches above; go-db does not switch
less than lean-db, it switches onto vCPUs that are still running). Two
differential runs point that way, though each changes more than that one
thing. With go-db at `GOMAXPROCS=1` (`bench/dbpairs.sh -g 1`; one
processor, so no idle one to spin on), six pairs gave go-db 8,454 to 14,883
requests per second at a p50 of 48 to 96 µs, lean-db/go-db 0.67 to 1.33
(median 0.86), and go-db's private cluster's CPU rose to 13 to 24 µs per
request, around lean-db's 19 to 21, although PostgreSQL makes the same
system calls per request for both servers. With ten `nice 19` busy loops
started in the container beside `bench/dbpairs.sh` to keep every vCPU awake
(four pairs of 50,000), lean-db's p50 fell to 41.5 to 41.9 µs, go-db's
usual p50, while both lost their throughput to the busy loops (p99 4 ms;
go-db's p50 2 ms), so only lean-db's p50 of that run is evidence. On macOS
the same commit gave 1.12 at c=1, and go-db there spent 83 µs of CPU per
request against 29 in the container. The 0.64 of rqc3ql's single
`bench.sh` run lies near this gap; the remaining gap at `GOMAXPROCS=1`
(median 0.86, pairs from 0.67 to 1.33) was not traced further. Whether
lean-db should spin before parking, which would trade idle CPU for
latency, is a separate decision that needs a measurement on the deployed
host's kernel first.

That measurement (item akj76n, run by item dtlin3 in the same window as
"HttpArena on the VPS": vps.frolow.dev, 2026-11-18, `bench/arena/run.sh db`,
the same scope and namespaces, as `nobody`, at 2ae7e98 with dtlin3's bench/
changes only) shows no such gap on the deployed host. `bench/dbpairs.sh`
(ten pairs of 100,000 requests at c=1): lean-db/go-db 1.08 to 1.32 (median
1.21); lean-db 3,247 to 3,661 requests per second, p50 254 to 282 µs, p99
511 to 654 µs, 121 to 134 µs of CPU per request, 1.76 to 1.86 voluntary and
0.34 to 0.51 involuntary switches per request; go-db 2,681 to 3,028, p50 311
to 344 µs, p99 615 to 776 µs, 216 to 245 µs of CPU, 8.53 to 8.80 and 1.79
to 1.88 switches; the private cluster's CPU 68 to 76 µs per request for
lean-db, 74 to 83 for go-db. With `-g 1`: 1.00 to 1.22 (median 1.09); lean-db
2,904 to 3,624 requests per second (p50 256 to 319 µs, 122 to 148 µs of
CPU), go-db 2,838 to 3,254 (p50 288 to 327 µs, 169 to 195 µs of CPU, 5.28
to 5.54 and 0.90 to 1.06 switches). A request on the VPS takes several times as
long as in the container, so these figures do not compare with the M1's. On
the deployed host lean-db is faster with Go's default GOMAXPROCS (ranges
apart) and spends less CPU per request in both runs; with `-g 1` their
throughput and p50 ranges overlap. Neither run shows a c=1 gap there for a
spin before parking to close.

Collecting rows in chunks (item 4lmjda) against single-row mode, measured
by `bench/rows.sh` (M1, 2026-11-17, load average 11 to 17 from other work,
two rounds of 8 s, a fresh `lsrv-db` per case, 8 loops with 4 connections
each, `GET /rows?n=N&len=L`: N rows of L bytes; server CPU µs per request,
then requests per second, one value per round):

| N, L, connections | single row | chunks of 16 | chunks of 64 | chunks of 256 |
|---|---|---|---|---|
| 1, 100, c=1 | 37, 37; 11,641, 11,670 | 41, 38; 9,815, 11,231 | 47, 37; 7,616, 11,444 | 37, 37; 12,518, 11,647 |
| 100, 100, c=1 | 97, 93; 6,409, 6,647 | 84, 82; 7,079, 7,042 | 82, 82; 6,890, 6,967 | 82, 82; 6,859, 6,791 |
| 1000, 100, c=1 | 621, 594; 1,238, 1,326 | 521, 497; 1,431, 1,524 | 504, 490; 1,450, 1,538 | 512, 510; 1,228, 1,238 |
| 1000, 100, c=64 | 732, 754; 6,989, 6,990 | 589, 601; 7,846, 7,791 | 585, 589; 7,564, 7,705 | 634, 628; 7,722, 7,295 |
| 900, 1000, c=64 | 4,236, 4,299; 1,235, 1,117 | 4,191, 4,242; 1,240, 991 | 4,259, 4,421; 1,212, 1,057 | 4,360, 4,334; 1,229, 1,080 |

Peak resident set size of the process, MB per round: at 1000 rows of 100
bytes and c=64, 28.6 and 28.1 single-row, 27.6 and 27.9 in chunks of 16,
26.2 and 26.2 of 64, 28.6 and 30.1 of 256; at 900 rows of 1000 bytes,
77.0 and 77.7, 77.9 and 77.3, 77.5 and 46.4, 99.6 and 140.5. The first
round's one-row runs in chunks of 16 and 64 were slower at a load average
of 14 to 17; three more rounds at one row against single-row mode, at a
load average of 10 to 14, gave 37 µs and 11,477 to 11,643 requests per
second for both single-row and chunks of 16 at c=1, and 41 to 46 µs,
73,614 to 76,359 for both at c=64 (chunks of 64: the same), so one row
costs the same. Chunks of 16 cost 12 to 20% less CPU per request at 100
and 1000 rows of 100 bytes and serve 11 to 16% more requests at 1000 rows;
chunks of 64 do the same within noise (1 to 3% less CPU, which a round's
spread covers) with four times the residual in libpq ("Bounded only in
part"), so 16 was chosen. Chunks of 256 gain no more CPU, serve no more
requests at 1000 rows and c=1 (not traced, since they were not chosen) and
raised the peak memory with large rows, as their larger residual predicts.
At 1000-byte rows the cost is in the data, not the per-row results, so no
mode differs within noise.

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
`mi_good_size` returns for the object, on the M1). Rechecked for
nightly-2026-11-17 (lean4 commit 55069db, item u4moqo): `src/runtime/object.cpp`,
`object.h`, `alloc.cpp` and `lean.h` are unchanged, mimalloc is still 3.4.5,
and `lsrv-test` measures the same bytes for every retained-state case:

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
holds its head; for a body or a request line, the socket queues (lsof on
macOS, `/proc` on Linux, checked first against as many connections whose
queues are known: `checkQueues`) show that the server has taken every byte
from its sockets, which does not exclude a receive not yet handed to Lean
(`awaitRead`): a drained queue does not prove that `Conn.step` processed the
bytes. At 4,096 connections, connections holding the request line with
8,176 query parameters would take about 2.0 GiB resident.

The last scenario: connections whose client writes 8,192 bytes at once (100
pipelined GETs of the fixture's largest response, then an unfinished
request) and never reads, measured with either parser from 50 to 100 such
connections (from none to 100 it also counts an apparent fixed component of
about 500 KiB; more connections made macOS deny network memory for the
stalled responses the kernel holds). The socket queues, read with lsof
on macOS and from `/proc/PID/net/tcp` and `tcp6` on Linux (each process's
own namespace, only the sockets among its descriptors, after a check
against connections whose queues are known: `checkQueues`), show before
each measurement that the server has read all 8,192 bytes and
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
and without them overlaps (90.6 to 91.5 against 90.6 to 90.9). The
snapshots are macOS only.

On Linux (the check container, `linux/Dockerfile`, OrbStack's arm64 VM,
2026-11-18, item kaslrv) the scenario ran on epoll and io_uring: 85.0 to
88.0 KiB per added connection with either parser (twenty runs), Lean's
mimalloc arena 68 to 71 KiB of it and glibc's malloc 17 KiB
(`/proc/PID/smaps`). `bench/boundary` turns transparent huge pages off for
itself and the servers it starts (`disableTHP`, checked before each
resident set sample): with them on (the host's `madvise`), the arena grew
in 2 MiB steps, 41 KiB per connection over the 50 added, and the scenario
read 58 or 99 KiB. The memory scenarios measure what a connection holds
under base pages, not the resident set of a server with huge pages, which
can hold memory in 2 MiB units. This scenario and those that wait on the
socket queues with `awaitRead` (`queueSettle`, item bfvj2q) are skipped on
systems other than macOS and Linux. Those three ran on Linux too (the same
container, one run per backend, 2026-11-18, item bfvj2q), per added
connection with H1 on epoll and io_uring: 51.9 and 51.8 KiB holding all but
one byte of a maximum body, 60.9 and 70.2 KiB for the nearly maximum head
received 7 bytes at a time, 495.6 and 483.2 KiB for the request line with
8,176 query parameters (28.9 and 28.8 KiB with the hand-written parser).

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
`lean-toolchain`, Zig 0.17, Go, PostgreSQL with `pg_config`, which
also provides libpq (Homebrew `postgresql@18`), and `bc`, without which
`bench.sh` stops at its start):

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

The H1 parse path as lsrv-arena drives it has a harness of its own, outside
both scripts (item r4q3yu, for item owgate): `lsrv-parsebench` runs
HttpArena's baseline (`get.raw`, `post_cl.raw`, one request per receive) and
pipelined (16 gcannon requests in one receive) shapes through the adapter's
parses of each receive (`parse`) and through `Conn.step` with `App.Arena`
(`step`), printing nanoseconds and allocations per request; `lsrv-parsebench
SHAPE LEVEL RECEIVES` runs one loop for a profiler. `lsrv-test` checks that
each shape completes its requests and gets `200` with App.Arena's body
(`Corpus.arenaShapesCheck`). `bench/parse/profile.sh OUT m1|linux [SHAPE LEVEL
RECEIVES]` records a call-graph profile of that loop: with Instruments' Time
Profiler (`xctrace`) on the M1, or with `perf record -g` in
`linux/Dockerfile`'s image with perf added (`bench/parse/Dockerfile`). No
figures from it are recorded here yet.

The boundary tests open thousands of loopback connections, and each closed
one stays in TIME_WAIT for 2*MSL (30 s on macOS) on the side that closed it
first. On the M1 (item laxhsb) the suite's two runs in one `check.sh` raised
the kernel's TCP PCB count (every TCP socket of the system) from about 800
to about 7,500; the ephemeral port range holds 16,384 ports. A third pair of
runs started at once after two others failed a dial with EADDRNOTAVAIL. So a `check.sh` or
`bench.sh` started within about 30 s of another connection-heavy run on the
same machine can fail for a reason that is not the change under test. Such a
failure stays a failure: the suite names EADDRNOTAVAIL as possible port
exhaustion, and `check.sh` prints the PCB count (system-wide, every TCP
socket) and the ephemeral port range before each run of the suite and after
a failing one, where `sysctl` has them (item vyzkxi).

`check.sh` runs `zig build test` against the one libpq `pg_config` names.
`./libpq-lines.sh PGSRC` runs it against every libpq line the pool supports
("Modules", `zig/`: 17 or later): the lowest supported release
and the newest release of each line from 17 up, built from the release tags
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

`./cleanup-controls.sh` checks the transport tests' cleanup
(`Single.deinit` in `zig/src/serve_test.zig`) with two negative controls
(`zig/src/cleanup_controls_test.zig`, run by `zig build cleanup-controls`):
a test that fails with connections open must fail with its own error, its
connections drained, and every test after it must pass; a test that passes
but leaves a connection open must be reported for the leak it logged at
error level (Zig 0.17.1's runner fails a passing test that logged an
error). The script checks those reports by name and the test counts, so a
compile error or any other failure fails it. It is opt-in, not part of
`check.sh` (item znorfg): run it at each update of Zig and for every change
to `Single.deinit`.

`./linux-check.sh` is the Linux validation (item ogcdwm): it builds the
Debian trixie image of `linux/Dockerfile` (Zig, the Lean toolchain of
`lean-toolchain` and Go at pinned versions and checksums; the base image
pinned by digest; PostgreSQL 17 as Debian's archive has it at the build)
with this machine's `docker` (on the M1, OrbStack) and runs the whole
`./check.sh` in it on a copy of the working tree: the transport's and the
pool's tests (`zig build test`), once on epoll and once on io_uring
(`LSRV_LINUX_BACKEND`; only that run turns the container's seccomp filter
off, as docker's default profile refuses `io_uring_setup`: acceptable for
this local developer container running the repository's own code, never
for production or for untrusted code), which serve_test.zig
checks is the backend in use, the database checks on the container's own private
cluster, and every other check. It prints the architecture, kernel, Debian,
Zig, Lean, Go, libpq, PostgreSQL and zio versions first, and fails when
libpq's or the server's major is not 17 or Zig is not on
`zig/build.zig.zon`'s `minimum_zig_version` line (the same major.minor,
and a patch at least the minimum's), so a rebuild that drifted fails instead of testing other
versions silently. To move the base image, take the index digest that
`docker buildx imagetools inspect debian:trixie` prints and note the date
beside it in `linux/Dockerfile`, and move the digest and date
of its copies in `bench/arena/local.Dockerfile` (the local HttpArena image)
and `bench/arena/gcannon.Dockerfile` (`bench/arena/build.sh`'s gcannon)
with them. It needs network access and
docker; `./check.sh` does not depend on it. Run it at each update of zio and
record its result in the commit. It is development evidence on the host's
architecture and the container runtime's kernel, not production
qualification: x86_64, kernel 6.12 and Debian 13's own kernel are not
covered by an OrbStack run; the suite's run on the deployed server's own
host is in "HttpArena on the VPS". Its last recorded result is in
`zig/src/serve_test.zig`'s header.

The scripts that build images on this machine's docker
(`./linux-check.sh`, `bench/arena/local.sh`, `bench/arena/build.sh`,
`bench/parse/profile.sh`) may run at once from several sessions and
worktrees against one daemon (item amjip6). Each run therefore tags its
images `NAME:run-…`, a tag of its own (`linux/run-images.sh`), runs those,
builds `bench/parse/Dockerfile` on its own base (`--build-arg BASE_IMAGE`),
and removes exactly those tags when it ends, also on SIGINT or SIGTERM (a
tag the daemon sets only after that cleanup, when the interrupt came as a
build was exporting its image, stays: `docker image ls '*:run-*'` lists
them); the download cache volumes stay shared, and docker's build cache
keeps a rebuild of unchanged Dockerfiles quick. No image is left tagged for later use: to
read a profile again, build the image as the script does.
`linux/run-images-test.sh` checks it with two overlapping runs whose
`linux/Dockerfile` differs by a marker, forced into the order that would
mix them up with a shared tag: each run's containers must report its own
marker, and each run's tags must be gone after it. Run it for every change
to how those scripts build or name images; it needs docker.

`./bench.sh` runs in the same image (item rqc3ql: it has `bc`, which
`bench.sh` needs for the CPU per request and lean's share of Go).
`./linux-check.sh` runs only `./check.sh`; to measure in the container,
build the image and run `./bench.sh` on a copy of the tree, as
`linux-check.sh` does (epoll, the build's default; the measurements are of
the container on this machine, comparable only with each other):

```sh
docker build -t lsrv-linux-check linux
git ls-files -z --cached --others --exclude-standard |
  COPYFILE_DISABLE=1 tar --null -T - -cf /tmp/lsrv-tree.tar
docker run --rm -v lsrv-linux-cache:/home/check/.cache \
  -v /tmp/lsrv-tree.tar:/tree.tar:ro lsrv-linux-check sh -c \
  'mkdir src && tar --warning=no-unknown-keyword -xf /tree.tar -C src && cd src && ./bench.sh'
```

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
at most 256 requests against hundreds of thousands. HttpArena's profiles on
Linux are in "HttpArena on the VPS".

## HttpArena on the VPS (items 53rwgc, dtlin3)

**These figures are a diagnostic, not a clean acceptance of ekklesiai.org's
speed requirement D2.** The load generator ran on the same 2 vCPUs as the
server, as the owner approved for these runs (2026-11-17, and under the
owner's delegation of 2026-11-18 for this rerun): throughput is a lower
bound, and latency and CPU per response are observations contaminated by
the generator. A clean D2 acceptance needs the generator on cores of its
own.

The figures below are item dtlin3's rerun (2026-11-18), after the accept
fix (item sakmfp). They replace item 53rwgc's (2026-11-17), which were
invalid for lsrv-arena: its transport then accepted one connection per loop
turn, so about half of the 4,096 connections were not served during a
sample and gcannon's figures covered only the others ("The over-5 s tail:
connections accepted late", below). git history keeps that run's tables.

What ran: HttpArena (https://github.com/MDA2AV/HttpArena, da3ded60952b) at
its HTTP/1.1 profiles this server owns, on vps.frolow.dev, the production
host (2026-11-17: x86_64, 2 vCPU Intel Xeon Gold 6152, 2.4 GB of memory,
kernel 6.12.74+deb13+1-amd64, Debian 13.4), with lsrv-arena (`MainArena.lean`,
`App/Arena.lean`: HttpArena's `/baseline11` and `/pipeline` as its go-stdlib
entry answers them) on epoll and on io_uring, built from main at 2ae7e98
(the accept fix is caeba5f; item dtlin3 changed only `bench/`), against
HttpArena's go-stdlib (the floor) and go-fasthttp (the target) entries. Five
rounds after one warm-up round, the contenders' order rotating each round,
a fresh server per sample. Versions: Lean nightly-2026-11-17, Zig 0.17.1,
zio 53ed3c377317, gcannon fb63bf61387314 (liburing 2.9) with
`bench/arena/gcannon-served.patch`, zrk 2.3.0, Go 1.27.3 for the Go entries.
lsrv-arena runs 2 loops with `--max-conns 16384`.

How (`bench/arena/`): `build.sh` cross-builds everything for x86_64 Linux on
the M1 (nothing is built on the host, whose disk is shared and nearly
full), and `run.sh tests|bench|db`, run as root on the host from the copied
directory (`/var/tmp/lsrv-arena-dtlin3`), runs it in a transient systemd
scope of its own (900 MB of memory, no swap) and fresh network and PID
namespaces (`inner.sh`), watching the site's health URL once a second and
ending the run at the first answer other than 200 or slower than 1 s.
`summarize.py` prints the tables below from the copied `out/` directory.
`run.sh db` runs `bench/dbpairs.sh` there (section "PostgreSQL").

Deviations from HttpArena's own run, all applied to every contender alike:
- Native processes in namespaces instead of HttpArena's docker containers,
  CPU pinning and host networking, and the generators with 2 threads
  (HttpArena's defaults assume a 64-core machine).
- baseline and limited-conn send HttpArena's GET and Content-Length POST
  templates, without its chunked POST: this server answers chunked request
  bodies 501 ("Not yet"), so HttpArena's validation check "POST
  /baseline11 chunked" fails for lsrv-arena. Every other check passes for
  every contender: the sums, a random sum, Content-Type, `/pipeline`, and
  16 requests pipelined on one connection.
- gcannon carries `gcannon-served.patch`, which only counts: its report
  gains "Connections served", the connection slots answered at least once
  in the measured window (after the warm-up). It is how this run counts the
  connections served, against the 4,096 configured; the host has no
  tracing tools, and the local diagnostic below traced accepts instead.
- Left out: async (each request answered after 10 ms: the handler has no
  timer, `Request → Await Response` waits only for queries, and adding one
  changes the architectural core), so memory under async is not measured;
  latency-1m (a million connections do not fit the host); and the profiles
  this server does not own (TLS, HTTP/2 and 3, compression, static files,
  databases, WebSocket).

The test suite on the host itself, before the runs: `zig build test`'s
binaries for x86_64 (from `build.sh`) passed on epoll and on io_uring each:
serve_test's 42 tests, pg_test's 38, and pg_glue_test.

Results, rounds 1-5: median (min-max) per sample; req/s counts 2xx responses
over the generator's window; CPU per response is the server's user and
system time over the whole generator run (connection set-up included)
divided by its responses; peak MB is the sample's own server's VmHWM. A
difference is resolved only where the ranges do not overlap. Every response
of every sample was 2xx (gcannon's status counts equal its responses), and
zrk reported no error. "over 5 s" counts responses slower than 5 s
(gcannon's latency overflow, outside its histogram, so its percentiles
leave them out); "served" is the patch's count of connections answered
in the window, of 4,096 (in limited-conn, connection slots, each reopened
after 10 requests, `-r 10`).

baseline (gcannon, 4096 connections, 5 s, GET and POST alternating):

| server | runs | req/s | p99 ms | p99.9 ms | CPU µs/resp | peak MB | non-2xx | over 5 s | served |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lsrv-epoll | 5 | 23,467 (22,246-25,189) | 847.9 (785.4-937.3) | 1480 (1410-1640) | 61 (57-63) | 84 (84-85) | 0 | 0 | 4,096 in each |
| lsrv-io_uring | 5 | 23,531 (21,626-25,709) | 588.9 (513.3-651.5) | 856 (753-909) | 61 (55-65) | 86 (84-86) | 0 | 0 | 4,096 in each |
| go-stdlib | 5 | 24,807 (24,209-29,147) | 1170.0 (596.1-1580.0) | 1510 (1290-2540) | 56 (47-57) | 141 (136-142) | 0 | 0 | 4,096 in each |
| go-fasthttp | 5 | 40,841 (38,047-43,383) | 299.6 (258.8-392.1) | 512 (457-710) | 27 (26-30) | 82 (82-83) | 0 | 0 | 4,096 in each |

pipelined (gcannon, 4096 connections, 16 requests in flight on each, 5 s):

| server | runs | req/s | p99 ms | p99.9 ms | CPU µs/resp | peak MB | non-2xx | over 5 s | served |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lsrv-epoll | 5 | 34,799 (32,016-35,920) | 3220 (2980-3580) | 3720 (3360-4120) | 37 (37-41) | 87 (86-89) | 0 | 0 | 4,096 in each |
| lsrv-io_uring | 5 | 35,492 (28,831-37,913) | 3070 (2830-3860) | 3570 (3250-4360) | 37 (34-46) | 87 (87-89) | 0 | 0 | 4,096 in each |
| go-stdlib | 5 | 42,108 (34,962-45,379) | 4460 (4020-4770) | 4710 (4390-4910) | 35 (31-40) | 73 (63-82) | 0 | 169 | 1,788 (1,463-2,118) |
| go-fasthttp | 5 | 421,898 (306,909-441,098) | 601.5 (373.6-911.2) | 976 (669-1490) | 3 (3-4) | 80 (79-83) | 0 | 0 | 4,096 in each |

limited-conn (baseline with a new connection after every 10 requests):

| server | runs | req/s | p99 ms | p99.9 ms | CPU µs/resp | peak MB | non-2xx | over 5 s | served |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lsrv-epoll | 5 | 23,113 (21,794-24,786) | 920.2 (836.5-970.2) | 1320 (1220-1440) | 60 (56-64) | 72 (68-74) | 0 | 0 | 4,096 in each |
| lsrv-io_uring | 5 | 22,142 (21,043-23,672) | 623.7 (542.6-717.8) | 828 (783-956) | 63 (58-66) | 107 (105-111) | 0 | 0 | 4,096 in each |
| go-stdlib | 5 | 22,298 (19,701-22,897) | 808.4 (766.7-952.8) | 1100 (882-1280) | 60 (59-69) | 150 (149-152) | 0 | 0 | 4,096 in each |
| go-fasthttp | 5 | 33,657 (31,682-34,835) | 327.0 (313.4-358.2) | 503 (479-542) | 34 (32-36) | 108 (102-113) | 0 | 0 | 4,096 in each |

latency-10k (zrk at a fixed 10,000 requests/s, 1024 connections, 20 s;
each run reached 99.2-99.5 % of the rate; no errors; zrk reports no p99.9
and no count of connections served):

| server | runs | req/s | p99 ms | CPU µs/resp | peak MB | non-2xx |
|---|---:|---:|---:|---:|---:|---:|
| lsrv-epoll | 5 | 9,937 (9,930-9,944) | 16.1 (14.1-28.8) | 80 (77-81) | 34 (33-34) | 0 |
| lsrv-io_uring | 5 | 9,941 (9,934-9,944) | 20.5 (13.3-47.7) | 77 (73-81) | 34 (33-34) | 0 |
| go-stdlib | 5 | 9,945 (9,924-9,951) | 15.2 (13.4-19.3) | 79 (77-81) | 44 (43-45) | 0 |
| go-fasthttp | 5 | 9,947 (9,935-9,954) | 5.4 (4.6-6.3) | 56 (53-58) | 32 (32-33) | 0 |

Read with the caveat above:
- The accept fix on the host: in every sample of every gcannon profile, on
  both backends, all 4,096 connection slots received a response in the
  window, and no recorded response took over 5 s (53rwgc: 50 and 62 in
  baseline, 603 and 591 in pipelined, over five samples). Its pipelined
  p99.9 is still 3.3 to 4.4 s; gcannon allows up to 65,536 requests in
  flight there (4,096 connections, 16 each) on 2 vCPUs, but how many were
  in flight was not measured.
- 53rwgc counted no connections served on the host; the local reproduction
  of its run (below) found about half of them answered. Its figures are
  therefore not compared with these: baseline throughput is lower than
  53rwgc's (about 23,500 per second against 31,500 to 33,800), p99 higher
  (0.5 to 0.9 s against about 65 ms), and peak memory higher (84 to 86 MB
  against about 40).
- go-stdlib in pipelined answered only 1,463 to 2,118 of the 4,096
  connections in a sample, and 169 of its responses took over 5 s; its
  pipelined figures cover only those connections. Its slow accepts under
  that profile were also seen locally (below); they are go-stdlib's own and
  were not traced further.
- Against the floor (go-stdlib): in baseline and limited-conn the
  throughput ranges overlap go-stdlib's, and so do the p99 ranges except
  lsrv-arena's on io_uring in limited-conn (543 to 718 ms against 767 to
  953); lsrv-arena's peak memory is lower in both (84 to 86 MB
  against 136 to 142 in baseline; 68 to 111 against 149 to 152 in
  limited-conn). In pipelined go-stdlib's figures do not cover all its
  connections, so they are not compared. latency-10k: the ranges overlap
  except peak memory (33 to 34 MB against 43 to 45).
- Against the target (go-fasthttp): ahead in throughput in every throughput
  profile, ranges apart: about 1.7 times in baseline, 1.5 in limited-conn
  and 12 in pipelined, with lower p99 and less CPU per response
  everywhere.
- epoll against io_uring: throughput and CPU per response overlap in every
  profile. io_uring's p99 and p99.9 are lower in baseline (p99 513 to 652
  ms against 785 to 937) and limited-conn (543 to 718 against 837 to 970),
  ranges apart; in pipelined both overlap, and so does p99 in latency-10k
  (zrk reports no p99.9). In limited-conn
  io_uring's peak memory is higher (105 to 111 MB against 68 to 74).

The site's health during the runs: 2,275 probes while the tests, the load
and `bench/dbpairs.sh` ran (18:41-19:24 UTC, `run.sh` tests 18:41, db
18:41-19:05, bench 19:09-19:24), every answer 200, the slowest 0.018 s,
and 75 before and after them, at most 0.003 s; the stop condition never
fired. No Sejm import was scheduled in that window (its timer runs at
05:30 UTC). Disk on the host: 3.7 GB free before the run's 446 MB were
copied, 3.3 GB during, 3.7 GB after its directory was removed.

### The over-5 s tail: connections accepted late (item 6p6tu6)

A diagnostic, reproduced locally before any use of the VPS:
`bench/arena/local.sh OUT ARENA [ROUNDS]` runs HttpArena's baseline and
pipelined profiles (gcannon, 4,096 connections, 5 s, at the commits
`build.sh` pins) against lsrv-arena on epoll, go-stdlib and go-fasthttp in
OrbStack's arm64 Linux VM on the M1 (kernel 7.2.12), each server and the
generator pinned to the same two CPUs, with `bench/arena/trace.bt`
(bpftrace) beside every sample: each connection's accept delay, from the
handshake's completion in the kernel to `accept(2)` returning it, and the
server's system calls; `PERF=1` adds a CPU profile (`perf record -g`). It is
a stress diagnostic on another machine and architecture, not a measurement
of the VPS. Two rounds, 2026-11-17 (`summary.txt`'s figures):

| server | profile | responses in 5 s | over 5 s | p50 / p99.9 | accepted during the load | slowest accept |
|---|---|---:|---:|---|---:|---:|
| lsrv-arena | baseline | 525,852; 559,356 | 10; 16 | 15 ms / 2.6 s | 2,257; 2,250 of 4,096 | 5.1 s |
| go-stdlib | baseline | 647,755; 663,316 | 0; 0 | 35 ms / 0.16-0.17 s | 4,096 | 0.16-0.17 s |
| go-fasthttp | baseline | 987,747; 1,036,942 | 0; 0 | 24 ms / 0.09-0.10 s | 4,096 | 0.01-0.08 s |
| lsrv-arena | pipelined | 795,825; 865,537 | 181; 142 | 150 ms / 4.7 s | 1,944; 2,111 of 4,096 | 5.1 s |
| go-stdlib | pipelined | 1,004,384; 978,977 | 0; 0 | 0.2 ms / 3.4-4.9 s | 4,096 | 1.5-3.0 s |
| go-fasthttp | pipelined | 8,694,368; 8,837,232 | 0; 0 | 43 ms / 0.13-0.14 s | 4,096 | 0.05-0.10 s |

The table's samples were taken before `trace.bt` was scoped to the
sample's network namespace and acknowledged its attachment itself; four
lsrv-arena samples after that change gave the same shape (accepted during
the load 2,311 and 2,343 of 4,096 in baseline, 1,978 and 1,998 in
pipelined; 14-20 and 208-218 over 5 s), and go-fasthttp's two 4,096.

The tail reproduces at the scale of item 53rwgc's VPS run (7-14 per
baseline sample, about 120 per pipelined one) and is not a lost wakeup or a
fairness bug among served connections: it is the accept path.
- **One accept per loop turn.** `acceptCb` (`zig/src/serve.zig`) handles the
  one connection its accept returned and adds the next accept. zio tries
  that accept at once, but queues its completion, and the callback runs only
  on the loop's next turn: `processCompletions` runs only what was queued
  when it began (zio 53ed3c377317, src/ev/loop.zig, "Drain only what was
  queued at entry ... The rest runs next tick"). So each loop takes one
  connection per turn, and a turn under this load runs the completions of
  hundreds of connections (2,478 `epoll_pwait2` and 2,481 `accept4` in a
  baseline sample, 1,942 and 1,946 in a pipelined one, for 0.5 and 0.8
  million responses). The Go servers accept in a loop of their own.
- **What gcannon shows of it.** gcannon starts its clock once every
  connection's handshake is done, which the kernel completes without the
  server, and sends each connection's first requests at once; it counts only
  answered requests, from their send. So about half the connections were
  never accepted during the load, invisible in its counts; those accepted
  near its end were answered after more than 5 s (in pipelined, 16 requests
  each: 142-181 over 5 s, 14-15 connections accepted after 5 s). Item
  53rwgc's VPS figures had the same shape; item dtlin3's rerun after the
  fix counted the connections served there (above): all 4,096, with no
  response over 5 s.
- **The check of the cause** (a diagnostic build, not committed): with
  `acceptCb` taking up to 64 more pending connections with `accept(2)`
  before it adds the next accept, every connection was accepted during the
  load, the slowest after 0.25-0.39 s, no response took over 5 s in two
  baseline and two pipelined samples, and p99.9 fell to 0.19-0.22 s
  (baseline) and 0.69 s (pipelined); the median rose (about 35 ms baseline,
  390-410 ms pipelined), as twice the connections then share the same two
  CPUs. Item sakmfp made that change (`LoopCtx.acceptMore`; "Production
  contract", "Admission"); its own run is below.
- io_uring was not traced locally; its completions take the same deferred
  path in zio's loop, and 53rwgc's VPS counts for it were the same.
- go-stdlib's pipelined samples also accepted slowly (up to 3 s) and
  showed a tail (0 here, 0 to 2,986 over 5 s in six other local samples,
  65 over five on the VPS); that is go-stdlib's own, not traced
  further.

What a pipelined response costs (lsrv-arena, the same runs): 1.02 `sendto`
per response (go-stdlib: 1.02 `write`; go-fasthttp: 0.063, one per 16) and
0.066 `recvfrom` (one per 16 requests). The transport tries each send
itself and reports it on the loop's next turn (`LoopCtx.readyCb`); only
then does `Conn.step` take the next pipelined request from the buffer, so a
connection's 16 pipelined responses take 16 sends and 16 turns. The CPU
profile (inclusive shares of the server's samples, pipelined; baseline in
parentheses): H1's parse (`H1Adapter.Parser.parse`) 41 % (39 %), the send
34 % (25 %), of it 27 % (20 %) in the kernel's `sendto` with loopback
delivery, the response's rendering and checks 8 % (8 % with the
application's sum), the deadline timers (`newArm`, `clearTimer`) 4 %
(4 %), the `recvfrom` calls 0.7 % (3.6 %), `epoll_pwait2` under 0.5 %. By
function, Lean's allocator and reference counting take about 20 % of all
samples. Each request starts a fresh H1 machine, which copies the rest of
the buffer (`buf.extract p.fed buf.size`) but parses only that request's
head: the parse costs about 3.8 µs per pipelined request against 5.9 µs per
baseline one (its share times the CPU per response below), though each
pipelined one is parsed from a buffer of up to 16, so it is not a re-parse
of the buffer. So pipelining saves only the receives; what remains per response is a parse
by H1 and a send of its own, where go-fasthttp writes 16 responses with one
send. Server CPU per response here: 9.2 µs pipelined, 15.2 µs baseline
(go-stdlib 7.4 and 11.3, go-fasthttp 0.8 and 6.2), whole-run CPU over the 5 s
window's responses.

After the fix (item sakmfp, 2026-11-17): the same script, two rounds, with
lsrv-arena built from the committed `acceptMore` (each accept callback
takes up to 64 connections). Every lsrv-arena sample accepted all 4,096
connections during the load, none after 1 s, and no response took over
5 s (gcannon printed no overflow line); each of its responses was 2xx,
and each of its servers printed `stopped` at its SIGTERM.

| server | profile | responses in 5 s | over 5 s | p50 / p99.9 | accepted during the load | slowest accept |
|---|---|---:|---:|---|---:|---:|
| lsrv-arena | baseline | 556,431; 521,054 | 0; 0 | 35-37 ms / 0.24-0.25 s | 4,096; 4,096 | 0.31-0.32 s |
| go-stdlib | baseline | 632,402; 616,999 | 0; 0 | 37-38 ms / 0.17-0.31 s | 4,096 | 0.13-0.34 s |
| go-fasthttp | baseline | 932,112; 1,023,968 | 0; 0 | 22-25 ms / 0.10-0.12 s | 4,096 | 0.06-0.09 s |
| lsrv-arena | pipelined | 747,171; 766,901 | 0; 0 | 421-432 ms / 0.74-0.76 s | 4,096; 4,096 | 0.42-0.45 s |
| go-stdlib | pipelined | 900,174; 1,045,860 | 1,155; 0 | 0.15 ms / 2.6-5.0 s | 4,096 | 2.6-4.9 s |
| go-fasthttp | pipelined | 9,085,952; 7,779,648 | 0; 0 | 42-46 ms / 0.16 s | 4,096 | 0.07-0.18 s |

lsrv-arena's responses now cover every connection, so they are not
comparable with the first table of this section, taken before the fix,
when about half the connections were accepted during the load; the median
rose as in the diagnostic build, since twice the connections share the two
CPUs. Item dtlin3 re-measured the VPS after the fix (above).

## `Std.Http.Protocol.H1` compared with the hand-written parser (item 7bccgi)

Toolchain leanprover/lean4 nightly-2026-11-14 (`lean-toolchain`); paths
below are under its `src/lean/Std/Http/`. Numbers from one `bench.sh` run on
the M1 (2026-11-16). Written before the module split: `Http.lean` is now
`Server/HandParser.lean`, `H1Adapter.lean` is `Server/H1Adapter.lean`,
`lsrv-h1` is now `lsrv` and the old `lsrv` is `lsrv-hand`; the adapter has
since started answering `Expect: 100-continue` (above). Line numbers are at
nightly-2026-11-14. The verdicts in "Where the verdicts differ" are at
nightly-2026-11-17 (item u4moqo), the first nightly with
https://github.com/leanprover/lean4/pull/16417; what that changed is listed
there.

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
256, `maxHeaderValueLength`, 400; 431 since nightly-2026-11-17); there is no limit on the whole head as in
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
differ) and 30,000 single-byte edits (2,701 differ; 2,732 at
nightly-2026-11-14). Every disagreement, grouped (an edit at a field's CRLF is
counted with the value it ends):

| input | hand-written | H1 | cases | what decides it |
|---|---|---|---:|---|
| Host value not a valid host (`a b`, `a@b`, `a:99999`, edited bytes, `::`) | ok | 400 | 971 | RFC 9112 §3.2: a server MUST answer 400 to a Host field with an invalid value. H1 conforms; the hand-written parser does not check Host syntax. |
| bare CR or bare LF in the head (CR or LF deleted, a byte inserted between them) | need-more until the buffer is full, then close without a response | 400 | 677 | RFC 9112 §2.2: a bare CR MUST be treated as invalid or replaced by SP; a lone LF MAY be accepted. Both conform; H1 answers at once. |
| method not a registered name (`BREW`, `get`, edited bytes) | ok (404), or 400 (7 cases) | 501 | 453 | RFC 9110 §9.1: methods are case-sensitive; an unrecognized one SHOULD get 501. H1 follows the SHOULD; the hand-written parser accepts any token and routes it to 404. |
| target not URI syntax (`/a#f`, `/a%zz`, `a`, non-ASCII byte, `/` deleted, edited bytes) | ok | 400 | 503 | RFC 9112 §3.2 (origin-form is an absolute path, no fragment) and §3: an invalid request line SHOULD get 400. H1 follows it. |
| `GET *`, `CONNECT a:443` with another Host | ok | 400 | 68 | RFC 9112 §3.2.4 (`*` only for OPTIONS), §3.2.3 and RFC 9110 §9.3.6 (authority-form only for CONNECT). H1 conforms. |
| header name over 256 bytes | ok | 431 | 40 | RFC 9110 §5.4: a server MAY reject a field it finds too large with a 4xx (431, RFC 6585 §5). Both conform; H1's `maxHeaderNameLength` is fixed at 256 here. |
| Connection value not a list of tokens (`close;x`, `% keep-alive`, `,` deleted) | keep alive unless it finds `close` | close | 350 | RFC 9110 §7.6.1 defines no handling of an invalid value; closing is the safer reading. |
| Transfer-Encoding with Content-Length, or not ending in `chunked`, or empty | 501 | 400 | 187 | RFC 9112 §6.1: TE with CL "ought to be handled as an error" and the connection closed; a coding the server does not understand SHOULD get 501. H1's 400 for codings that cannot frame the body follows §6.3 (3); either status is defensible. |
| Content-Length `99999999999` | 400 | 413 | 22 | RFC 9110 §8.6 (a valid number) and §15.5.14: a body over the limit gets 413; the hand-written parser rejects more than 10 digits as invalid. Both close. |
| HTTP/0.9, HTTP/2.0, HTTP/0.1, HTTP/9.0 | 400 | 505 | 86 | RFC 9110 §15.6.6: 505 for an unsupported major version. H1 is more precise. |
| HTTP/1.2, HTTP/1.9 | 400 | ok, as 1.1 | 41 | RFC 9110 §6.2: a recipient SHOULD process a higher minor version as the highest it supports. H1 conforms. |
| empty line before the request line | 400 | ok | 35 | RFC 9112 §2.2: a server SHOULD ignore at least one empty line before the request line. H1 conforms. |

In short, H1 rejects more malformed input, follows RFC 9112 and 9110 at least
as closely in every group, and no longer waits for more bytes where the
hand-written parser rejects. Neither parser accepted anything the other framed differently: no request was
consumed with a different length or body by the two.

What https://github.com/leanprover/lean4/pull/16417 (merged as
13921a64bf71, first in nightly-2026-11-17) changed in these verdicts, from
`lsrv-compare` on the same commit of this repository under both toolchains
(item u4moqo); the valid requests and the limits at their boundaries give the
same results under both:

- No SP between target and version (`GET /xHTTP/1.1`, CR or DEL in its
  place, 7 cases): H1 answered need-more, reading the target up to the next SP
  and answering 414 only after 8,192 bytes
  (https://github.com/leanprover/lean4/issues/16479, filed from D1's option
  2); it now answers 400 as the hand-written parser does. No case is left
  where H1 waits for more bytes and the hand-written parser rejects.
- SP inserted in or replacing a byte of the method (24 cases): H1 answered
  501; it now answers 400 as the hand-written parser does (RFC 9112 §3: an
  invalid request line).
- A header name over 256 bytes (40 cases): H1 answered 400; it now answers
  431, as for a value over `maxHeaderValueLength`.

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
