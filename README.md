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
the requiring package. An executable that runs the transport also links
libpq: give it `moreLinkArgs := #["-lpq"]` and put `pg_config --libdir` on
`LIBRARY_PATH`. Its composition root imports `Server.Transport`, one adapter
(`Server.H1Adapter`) and the application, and declares
`server_exports (Server.H1Adapter.handle app)`; see `Main.lean`. Pin the same
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
| `Server.Wire` | the limits and `Server.Reply`, the adapter's answer to the bytes buffered on a connection | `Server.Query` |
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
  thread, all accepting on one listening socket on 127.0.0.1:8083; it prints
  `ready` once every loop has registered its acceptor. The loop keeps no
  protocol or buffering state: each connection holds a Lean `Conn.State`,
  reports the outcome of every operation to it through `src/glue.c`, and
  performs the action it answers. Worker threads call
  `lean_initialize_thread`, which libleanrt exports but `lean.h` does not
  declare. It keeps at most one operation in flight per connection and ends
  the process when a completion finds none outstanding. Reusing a
  connection's completion from its own callback relies on zio's contract
  (pinned 9bef33d, `src/ev/loop.zig` `finishCompletion`): the completion is
  marked dead before its callback runs, and for a completion without a group
  owner the callback is the last thing the loop does with it. Each loop
  also owns a PostgreSQL pool (`src/pg.zig`, section "PostgreSQL"). The
  library needs libpq's headers (`-Dpq-include`) and the servers link
  `-lpq`.
- Command line: `lsrv [THREADS] [--max-conns N] [--pg CONNINFO]
  [--pg-conns N]` (`--pg-conns`, default 4, is per loop; without `--pg` no
  pool is made and every query fails with `08006`), then the test settings:
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
  supervisor restarts it. Unresolved: Linux documents further errors of a
  pending connection (`ENETUNREACH`, `EHOSTUNREACH`, `EHOSTDOWN`, `ENONET`,
  `ENOPROTOOPT`, `EOPNOTSUPP`, accept(2): "treat them like EAGAIN"), but the
  pinned zio maps them to `Unexpected` or `OperationNotSupported`, which also
  stand for errors of a broken listening socket (`src/os/net.zig`,
  `errnoToAcceptError`), so they end the process too. Re-arming on them
  would spin on a broken socket; distinguishing them needs zio's error set.
  Left to the owner.
- **Shutdown.** SIGTERM or SIGINT starts a graceful shutdown: each loop stops
  accepting (its armed accept is canceled; a connection accepted meanwhile is
  closed), cancels every receive in flight and declines every later one
  (`Conn.Event.refused`, which closes the connection), lets every send run to
  completion, so a response already started arrives whole and requests
  already buffered are answered, and its `loop.run` returns once nothing of
  it is in flight: every completion queued before the stop has been
  dispatched. When all loops have returned the process prints `stopped` and
  exits with status 0. A peer that does not read its response holds the
  shutdown until it does; ending that wait is the supervisor's deadline
  (SIGKILL), not the server's.
  A query in flight or waiting for a pool slot also holds the shutdown
  until it is answered (section "PostgreSQL").
- **Not yet:** idle, read and write deadlines per connection (a peer can hold
  a connection slot as long as it likes), deadlines for queries, chunked
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
  borrow another's idle connections). Connections open on demand, for the
  query that needs one; a query that finds every slot busy waits in the
  loop's FIFO queue, which holds at most one query per HTTP connection.
  zio's socket registry keeps a registration per descriptor until a
  `NetClose`, while libpq closes and replaces its own socket, so the pool
  polls a duplicate of libpq's descriptor that it owns and closes with
  `NetClose` (`zig/src/pg.zig`, its header).
- **Statements.** Each connection prepares a statement for each distinct
  `Query.sql` on its first use (one round trip: Prepare, execute and Sync in
  libpq's pipeline mode) and executes it by name after that, as pgx does;
  past 64 statements on a connection further texts run unnamed. So a query
  must not deallocate statements (`DEALLOCATE`, `DISCARD ALL`), and a
  statement whose result type changes after a schema change fails until the
  connection is replaced. Parameters and results are text; one statement per
  query.
- **Results and errors.** Every query is answered exactly once: rows (text
  values, `none` for NULL, invalid UTF-8 replaced), PostgreSQL's error with
  its SQLSTATE, or a pool error: `08006` when the connection could not be
  made or was lost (also for a query in flight when the server restarts),
  `54000` for a query that cannot be sent (a NUL byte, more than 65,535
  parameters) or a result over `Query.maxResultBytes` (1 MiB of text). A
  query is never retried: once it may have reached the server, a lost
  connection fails it, and its outcome is unknown (a write may have been
  committed); the next query opens a fresh connection. Likewise a process
  that ends after a query was sent leaves its outcome to PostgreSQL, as
  for any client that disconnects. With the
  database down every query fails at once with `08006` after its own
  connection attempt; there are no timers, backoff or circuit breaker.
  `App.Db` answers class 08 with 503 and other errors with 500.
- **Liveness.** An idle connection keeps its receive armed, so a connection
  the server closed is ended when the loop handles its EOF. This is best
  effort: a query the loop dispatches before handling the EOF fails with
  `08006`.
- **Sessions.** Each query is its own implicit transaction. A query that
  leaves a transaction open or failed (`BEGIN`) is answered `25000` and its
  session is closed, which rolls the transaction back, so no query runs in
  another's transaction. Other session state (`SET`, session-level advisory
  locks, temporary tables) stays with the session for later queries of any
  request; queries must not change it (`Server.Query`).
- **Connection string.** `--pg` is a libpq conninfo; the pool adds
  `client_encoding=UTF8`. It must name a Unix socket directory or a
  `hostaddr`: libpq resolves a host name synchronously, which would block
  the loop.
- **Tests.** `bench/dbcheck` runs `lsrv-db` against the private cluster.
  What a real cluster cannot force is tested deterministically by
  `zig build test` in `zig/` (`bench.sh` runs it). `src/pg_test.zig` runs
  `pg.zig`'s pool on a real loop and real sockets with a scripted fake in
  place of `pg.c`: a partial flush with both polls outstanding and the
  write completion arriving after the slot went idle, a session ended
  (COPY) with both polls outstanding, and synchronous chains of 10,000
  failing queries (no slots, the database down) that stay iterative.
  `src/pg_glue_test.c` runs `pg.c` and the real libpq against a fake
  PostgreSQL server on a Unix socket, each reply delivered whole, a message
  at a time and a byte at a time: command boundaries and Sync, errors,
  COPY in and out, a transaction left open, a connection lost mid-reply.
  A chain of queries that fail synchronously, each asked again from its
  error, runs entirely inside the `submit` that started it: the loop serves
  nothing else until the chain ends.
- **Not bounded yet:** libpq gathers a whole result before the size check,
  so a query returning more than 1 MiB costs that memory until it is
  refused; a query or a connection attempt has no deadline, so a stuck
  database holds connections, and shutdown, until it answers.

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

Retained per connection, bounded whatever the peer does (a waiting query
adds its `Server.Query` and continuation, bounded by what the handler builds,
and a result of at most `Query.maxResultBytes` of text while it is turned
into the continuation's answer): the loop's
connection (two 8,192-byte buffers and its fields, a little over 16 KiB), the Lean
buffer of unconsumed bytes (at most `inCap` = 16,388 bytes,
`Conn.step_inv`), and a response being sent (at most 65,536 bytes,
`Conn.step_inv`): about 98 KiB at most, so `--max-conns` × 98 KiB in all
(about 392 MiB at the default 4,096). `Conn.step_inv` bounds the lengths
of the Lean byte arrays, not their capacities: an array grown by appending
may hold more capacity than its length, so the bound on allocated memory is
the stated one only up to that slack (at most about twice the lengths).
Transient allocations during one
parse are not in this bound; each loop runs one parse at a time, so they are
bounded per loop, not per connection. Measured by `bench/boundary` (1,000
connections, each holding an 8,000-byte head while it waits for its body
after `100 Continue`): 42.4 KiB per connection of resident set growth on the
M1 (2026-11-16), under the stated bound. That measurement holds heads and
the interim response only; it does not fill each connection's input buffer
and output at once, so it does not establish the worst case.

## Fragmented requests (decision D1)

Every receive makes the adapter parse the whole buffer again, so a request
split into many receives costs time quadratic in its size, for both parsers.
`lsrv-bench` feeds requests to `Conn.step` in receives of k bytes (M1,
2026-11-16; CPU time per request):

| request | bytes | k | receives | hand-written ms | H1 ms |
|---|---:|---:|---:|---:|---:|
| browser GET, 16 headers | 789 | 1 | 789 | 1.2 | 13.4 |
| browser GET, 16 headers | 789 | 1,460 | 1 | 0.0 | 0.1 |
| largest head | 8,196 | 1 | 8,196 | 145 | 234 |
| largest head | 8,196 | 7 | 1,171 | 34 | 62 |
| largest head | 8,196 | 64 | 129 | 3.8 | 7.1 |
| largest request | 16,388 | 1 | 16,388 | 1,405 | 4,233 |
| largest request | 16,388 | 7 | 2,342 | 192 | 598 |
| largest request | 16,388 | 64 | 257 | 12 | 62 |
| largest request | 16,388 | 1,460 | 12 | 1.0 | 3.5 |

The memory bounds above hold for any split, since the buffer never exceeds
`inCap`; by D1's condition they do not block H1's adoption. The CPU does not
have such a bound: a peer that sends the largest request one byte per
segment costs a loop about 4.2 s of CPU in all with H1 (1.4 s with the
hand-written parser). It is spread over the receives, each of which parses
at most 16,388 bytes, so the loop serves its other connections in between;
but a few such peers take most of a loop's CPU. Not worked around here
(D1: no local workaround of the parser); keeping the parser's state across
receives changes the adapter's interface and is a separate decision.

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
`Conn.step`), the module boundary check (`lsrv-arch`), the parser comparison
and benchmark (`lsrv-compare`, `lsrv-bench`), the boundary tests and the
end-to-end checks (the last two against both parsers), then measures each
server at 1, 64 and 256 connections for 10 s, printing requests per second,
latency percentiles and server CPU time per request; the Lean servers must
then stop gracefully on SIGTERM. Then it creates a private PostgreSQL
cluster under its temporary directory (a Unix socket there, no TCP
listener; any other PostgreSQL on the machine is not touched), runs
`bench/dbcheck` and measures `lsrv-db` against `bench/pgserver`. Any failure stops it with a nonzero status,
and every server it started is stopped on exit. A server that stops
answering keeps it from ending; that is a failure to trace, never a result.

`bench/boundary` starts the fixture server (`lsrv-fixture`, and
`lsrv-fixture-hand` with `-no-continue`) with the test settings and checks:
exact 60,001-byte responses through 7-byte operations, split and pipelined
requests, injected failures, 2,000 connections closed or reset at different
points, `100-continue` and a response over the bound, the graceful shutdown
with a response in flight and an idle and a partial connection, admission at
`--max-conns 2`, the two crash points, and the memory per connection; every
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
