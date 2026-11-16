# Spike: Lean HTTP/1.1 on zio.ev

A disposable experiment for item `dqsipn` (see `issues/dqsipn.md` for the
numbers and the decisions around it). It asks whether a Lean application can
serve HTTP as fast as Go's `net/http` and dusty, when its event loop comes
from [zio](https://github.com/lalinsky/zio) instead of Lean's `Std.Async`.
It is not production code; what production needs beyond it is listed in the
item.

- `zig/`: a static library; `bench.sh` builds it in ReleaseSafe (bounds and
  overflow checks) unless `ZIG_OPTIMIZE` says otherwise. One `zio.ev` loop per thread, all
  accepting on one listening socket on 127.0.0.1:8083; it prints `ready` once
  every loop has registered its acceptor. The loop keeps no protocol or
  buffering state: each connection holds a Lean `Conn.State`, reports the
  outcome of every operation to it through `src/glue.c`, and performs the
  action it answers. Worker threads call `lean_initialize_thread`, which
  libleanrt exports but `lean.h` does not declare. It keeps at most one
  operation in flight per connection and ends the process when a completion
  finds none outstanding. Test settings, given on the command line after the
  loop count: `--chunk N` caps every receive and send at N bytes, `--fail-every
  N` reports every N-th completed receive and every N-th completed send to
  Lean as failed, and `--trace`
  prints `open <id>` and `free <id> <operations>` per connection and keeps
  freed connections allocated, so a late completion hits that check. Reusing
  a connection's completion from its own callback relies on zio's contract
  (pinned 9bef33d, `src/ev/loop.zig` `finishCompletion`): the completion is
  marked dead before its callback runs, and for a completion without a group
  owner the callback is the last thing the loop does with it.
- `lean/Conn.lean`: the connection's lifecycle as one state type (reading,
  writing, closed) and a pure `step` over the loop's events, generic over the
  request handler, with theorems: the buffer never exceeds the largest
  accepted request, a closed connection stays closed and asks for nothing,
  the close action always leaves it closed, every receive has room and every
  send has at least one byte. What the theorems assume about the loop is in
  the module's docstring.
- `lean/Http.lean`: the protocol work. It frames requests (head up to 8 KiB,
  Content-Length body up to 8 KiB, pipelining), validates the request line and
  every header field, applies Content-Length, Host, Connection and
  Transfer-Encoding rules (chunked bodies get 501), routes GET and HEAD `/`
  (methods compared case-sensitively), and builds Content-Type, Date,
  Content-Length and Connection headers; `handle` answers need-more or a
  response with the bytes it consumes. `lean/Serve.lean` starts the loops and
  reads the command line; `lean/Main.lean` (`lsrv`) exports the loop's entry
  points for `handle`, and `lean/Fixture.lean` (`lsrv-fixture`) for a test
  handler whose `/` body is 70,001 bytes, several times the loop's send buffer;
  `lean/Test.lean` tests `handle` and `Conn.step` without sockets (statuses,
  every proper prefix of complete requests, limits at their exact boundaries,
  dates, and one connection through split receives and a partial send).
- `dusty-hello/`: the same route on dusty, the HTTP library on zio.
- `bench/`: Go's `net/http` with the same route (`goserver`), end-to-end
  checks over real sockets (`check`), tests of the Zig/Lean boundary
  (`boundary`: it starts `lsrv-fixture` with the test settings and checks
  exact large responses through 7-byte operations, split and pipelined
  requests, injected failures, and 2,000 connections closed or reset at
  different points, each accepted connection freed exactly once), and a
  closed-loop keep-alive load
  generator (`load`) that counts only responses with status 200 and the
  expected body and fails on anything else.
- The toolchain's own parser, for item `7bccgi` (section below):
  `lean/H1Adapter.lean` puts `Std.Http.Protocol.H1` behind `Http.handle`'s
  shape; `lean/MainH1.lean` (`lsrv-h1`) and `lean/FixtureH1.lean`
  (`lsrv-fixture-h1`) are `lsrv` and `lsrv-fixture` with it, the fixture's body
  now in `lean/FixtureBody.lean`; `lean/Compare.lean` (`lsrv-compare`)
  compares the two parsers' verdicts, `lean/Bench.lean` (`lsrv-bench`) their
  cost, both over the requests in `lean/Corpus.lean`.

Run everything (macOS or Linux; needs the Lean toolchain from
`lean/lean-toolchain`, Zig 0.17 and Go):

```sh
spike/zio-http/bench.sh
```

It builds all parts, runs the Lean tests, the parser comparison and
benchmark, the boundary tests and the end-to-end checks (the last two against
both Lean parsers), then
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

## `Std.Http.Protocol.H1` compared with the hand-written parser (item 7bccgi)

Toolchain leanprover/lean4 nightly-2026-11-14 (`lean/lean-toolchain`); paths
below are under its `src/lean/Std/Http/`. Numbers from one `bench.sh` run on
the M1 (2026-11-16).

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

### Proposal for D1 (not decided here)

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
  Lean loop asks for 4,096 (`zig/src/serve.zig:302`). A Go program that
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
still fails at 256 connections now and then for this reason (in the loop
above, about one run in four for dusty and one in ten for Go): of its two
runs for this item, the first passed and the second failed at dusty c=256
with `read: connection reset by peer` on 4 connections. Why Lean's
loop drains the queue fast enough and dusty's does not was not traced: more
accept loops in dusty did not remove the failures. A fix in the load generator
(open the connections before the measurement, with at most 128 of them
waiting for their first response at a time, a response being what shows the
server accepted the connection) is proposed as a follow-up, not made here.
