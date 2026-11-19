# Lean HTTP/1.1 server on zio.ev

A Lean 4 HTTP/1.1 server library on per-core `zio.ev` event loops, with
PostgreSQL access from the loops. It was written for ekklesiai.org, which
depends on it, and started there as a spike. The application is a pure
Lean function, `Request → Await Response`; the transport (Zig, `zig/`)
knows neither HTTP nor the application, and requests are parsed by
`Std.Http.Protocol.H1` from the Lean toolchain.

## Status and known limits

It serves ekklesiai.org's production host (Linux, epoll). It is tested on
macOS (kqueue) and, in a Debian container, on Linux with epoll and
io_uring; that container run is development evidence, not production
qualification ([Running](docs/running.md)).

- **Requests:** HTTP/1.0 and 1.1, heads of at most 8,192 bytes and 100
  fields, Content-Length bodies of at most 8,192 bytes, pipelining,
  `Expect: 100-continue`. Not yet: chunked request bodies (answered 501),
  percent-decoding and query parsing, Go's larger limits.
- **Responses** are written whole, at most 65,536 bytes; no streaming.
- **Deadlines** for every phase of a connection and for every query. A
  connection deadline closes the connection without a response; a query
  deadline instead returns `57014` to the handler, which can still
  respond.
- **State is volatile:** a crash can leave a response cut short and a
  query's outcome unknown; queries are never retried.
- **PostgreSQL** needs libpq 17 or later and a Unix socket or `hostaddr`
  (no host name lookup). libpq's memory for a result is bounded only in
  part.
- **Memory:** while a request is incomplete, a connection holds at most
  about 310.2 KiB of live blocks besides its small Lean objects, half of
  it H1's parsed request-target (at most 255 path segments and 1,000 query
  parameters; more get 414); one waiting for a query holds instead
  its buffer, what the handler built and a result of at most 1 MiB, and
  libpq's buffers are the pool's. Derived, not a cap to size a deployment by.

The details of each are in the [production contract](docs/production-contract.md),
[PostgreSQL](docs/postgresql.md) and [Memory](docs/memory.md). Open work is
queued in `issues/` (order in `issues/ORDER`).

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

- Contracts: `Server.Query` (a query and its result as values, and
  `Await`), `Server.Wire` (limits, the adapter's interface) and
  `Server.Handler` (`Request → Await Response`, which the application
  implements).
- `Server.Conn`: a connection's lifecycle, a pure `step` with theorems.
- `Server.Transport` and `zig/`: the event loops, the PostgreSQL pool and
  the command line (`lsrv [THREADS] [--port N] ...`).
- `Server.H1Adapter` (the production adapter) and `Server.Response`.
- `App.*`: the example, test and benchmark applications; `Main*`,
  `Fixture*`: their composition roots.

[Modules](docs/modules.md) has every module, what each may import (which
`lsrv-arch` enforces), the transport and the command line.

## Running

Needs the Lean toolchain from `lean-toolchain`, Zig 0.17, Go, PostgreSQL
with `pg_config` and libpq 17 or later, and `bc`.

| command | what it checks |
|---|---|
| `./check.sh` | the relative links and anchors between the Markdown files, the builds the tests need (not the benchmarks'), the Lean tests, the module boundaries, the transport's and the pool's tests, the boundary and end-to-end checks against both parsers, and the database checks on a private PostgreSQL cluster |
| `./bench.sh` | `./check.sh`, then the measurements against Go and dusty; the gate for integrating a change |
| `./libpq-lines.sh PGSRC` | the pool's tests against every supported libpq line |
| `./cleanup-controls.sh` | the negative controls of the transport tests' cleanup |
| `./linux-check.sh` | `./check.sh` in a Debian container, on epoll and on io_uring |

[Running](docs/running.md) says what each runs, when to run it, and how to
read the measurements.

## Documentation

Reference (kept accurate with the code):

- [Modules](docs/modules.md): modules, allowed imports, the transport, the
  command line.
- [Production contract](docs/production-contract.md): effects, requests,
  responses, deadlines, admission, accept errors, shutdown, transport tests.
- [PostgreSQL](docs/postgresql.md): the pool, statements, results and
  errors, deadlines, sessions, tests.
- [Memory](docs/memory.md): what a connection holds, derived and measured.
- [Fragmented requests (decision D1)](docs/fragmented-requests.md).
- [Running](docs/running.md): the scripts and checks in detail.
- [Upstream reports](docs/upstream/): drafts of reports to the Lean
  toolchain, with reproducers.

Reports (historical records of measurements and investigations, each
naming its date and what it measured):

- [HttpArena on the VPS](docs/reports/httparena-vps.md)
- [The over-5 s tail: connections accepted late](docs/reports/over-5s-tail.md)
- [PostgreSQL measurements: lean-db against Go](docs/reports/postgresql-throughput.md)
- [What the dependency assumptions rest on](docs/reports/dependency-assumptions.md)
- [`Std.Http.Protocol.H1` compared with the hand-written parser](docs/reports/h1-vs-hand-parser.md)
- [Where H1's parse spends lsrv-arena's CPU](docs/reports/h1-parse-profile.md)
- [One step on a full buffer of pipelined requests](docs/reports/full-buffer-step.md)
- [The dusty failure at 256 connections](docs/reports/dusty-256-connections.md)
- [dusty on the real zio](docs/reports/dusty-real-zio.md)
- [Why the 7-byte receive row of Memory grew](docs/reports/chunked-receive-memory.md)

Decisions: decision D1 (the HTTP/1.1 parser) is recorded in ekklesiai.org,
in its decision record 0001
(`docs/decisions/0001-lean-http-server-on-zio.md`, section "D1: the
HTTP/1.1 parser"), which names this queue's item 53rwgc as pihgvg. Other
decisions are stated where they apply, with the item that made them; ids
of the spike's items (`dqsipn`, `7bccgi`, `2l6rcv`, ...) name ekklesiai.org's
queue items, the others this repository's, and `git log --grep ID` finds
their commits.
