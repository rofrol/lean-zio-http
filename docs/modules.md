# Modules

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
| `App.Arena` | HttpArena's HTTP/1.1 endpoints ([HttpArena on the VPS](reports/httparena-vps.md)) | `Server.Handler` |
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
  carries no data ([Production contract](production-contract.md), "Deadlines"),
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
  poll starts beside it ([Production contract](production-contract.md), "Deadlines"), only after the kernel said
  EAGAIN, whatever the backend. zio's io_uring backend would otherwise queue
  every send untried, and each would look parked. The deployed server runs
  on epoll: the measurements on its host after the accept fix
  ([HttpArena on the VPS](reports/httparena-vps.md)) resolve no difference in throughput or
  CPU between the two backends; io_uring's p99 there is lower in two
  profiles of four.
  Each loop
  also owns a PostgreSQL pool (`src/pg.zig`, [PostgreSQL](postgresql.md)). The
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
  the four connection budgets, in milliseconds, are in [Production contract](production-contract.md), "Deadlines",
  the four database budgets in [PostgreSQL](postgresql.md), "Deadlines",
  the drain in [Production contract](production-contract.md), "Shutdown"), then the test
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
  `deadline.Watch.wait` is gone and `AutoCancel.setClock` is linked. Its throughput before and after:
  [dusty on the real zio](reports/dusty-real-zio.md).
- `bench/`: Go's `net/http` with the same route (`goserver`) and with
  `App.Db`'s `/db` route over a pgx pool (`pgserver`), end-to-end checks over
  real sockets (`check`), the boundary tests (`boundary`, [Running](running.md)), the
  PostgreSQL tests (`dbcheck`, [Running](running.md)), a closed-loop keep-alive load
  generator (`load`) that counts only responses with status 200 and the
  expected body and fails on anything else, and the check of the Markdown
  files' relative links and anchors (`mdlinks`).
