# Spike: Lean HTTP/1.1 on zio.ev

A disposable experiment for item `dqsipn` (see `issues/dqsipn.md` for the
numbers and the decisions around it). It asks whether a Lean application can
serve HTTP as fast as Go's `net/http` and dusty, when its event loop comes
from [zio](https://github.com/lalinsky/zio) instead of Lean's `Std.Async`.
It is not production code; what production needs beyond it is listed in the
item.

- `zig/`: a static library. One `zio.ev` loop per thread, all accepting on
  one listening socket on 127.0.0.1:8083; it prints `ready` once every loop
  has registered its acceptor. The loop only moves bytes: it hands everything
  buffered on a connection to Lean through `src/glue.c` and sends what Lean
  returns, after checking the result's prefix. Its input buffer holds exactly
  the largest request Lean accepts (8192 + 4 + 8192 bytes). Worker threads
  call `lean_initialize_thread`, which libleanrt exports but `lean.h` does not
  declare.
- `lean/Http.lean`: the protocol work. It frames requests (head up to 8 KiB,
  Content-Length body up to 8 KiB, pipelining), validates the request line and
  every header field, applies Content-Length, Host, Connection and
  Transfer-Encoding rules (chunked bodies get 501), routes GET and HEAD `/`
  (methods compared case-sensitively), and builds Content-Type, Date,
  Content-Length and Connection headers. Its result starts with a 5-byte
  prefix: the kind (need more bytes, respond, respond and close) and the
  number of bytes consumed. `lean/Main.lean` starts the loops;
  `lean/Test.lean` tests `handle` without sockets (statuses, every proper
  prefix of complete requests, limits at their exact boundaries, dates).
- `dusty-hello/`: the same route on dusty, the HTTP library on zio.
- `bench/`: Go's `net/http` with the same route (`goserver`), end-to-end
  checks over real sockets (`check`), and a closed-loop keep-alive load
  generator (`load`) that counts only responses with status 200 and the
  expected body and fails on anything else.

Run everything (macOS or Linux; needs the Lean toolchain from
`lean/lean-toolchain`, Zig 0.17 and Go):

```sh
spike/zio-http/bench.sh
```

It builds all parts, runs the Lean tests and the end-to-end checks, then
measures each server at 1, 64 and 256 connections for 10 s, printing
requests per second, latency percentiles and server CPU time per request.
Any failure stops it with a nonzero status, and every server it started is
stopped on exit. A server that stops answering keeps it from ending; that is
a failure to trace, never a result.

Reading the numbers: the load generator runs on the same machine, so at 64
and more connections it is the limit; compare the 1-connection rows and the
CPU per request. The servers differ in features and limits (below), and
closed-loop latency hides queueing under overload. Acceptance runs belong on
Linux with HttpArena's tooling (see the item).

What the Lean side does not do yet, unlike Go: chunked request bodies, a map
of all headers for the application, percent-decoding and query parsing,
`Expect: 100-continue`, Host syntax checks, and Go's larger limits.
