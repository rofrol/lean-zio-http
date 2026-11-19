# `Std.Http.Protocol.H1` compared with the hand-written parser

Measured on 2026-11-16 on the M1 by the spike's item 7bccgi (an
ekklesiai.org queue item; recorded here in 04b6e31), with the toolchain
nightly-2026-11-14; "Where the verdicts differ" was updated at
nightly-2026-11-17 (item u4moqo). Its proposal led to decision D1, recorded
in ekklesiai.org's decision record 0001. A historical record, kept as it was
written and not updated as the code changes; the current contracts are in
the documents [README.md](../../README.md#documentation) lists. Item ids
name queue items; `git log --grep ID` finds their commits.

Toolchain leanprover/lean4 nightly-2026-11-14 (`lean-toolchain`); paths
below are under its `src/lean/Std/Http/`. Numbers from one `bench.sh` run on
the M1 (2026-11-16). Written before the module split: `Http.lean` is now
`Server/HandParser.lean`, `H1Adapter.lean` is `Server/H1Adapter.lean`,
`lsrv-h1` is now `lsrv` and the old `lsrv` is `lsrv-hand`; the adapter has
since started answering `Expect: 100-continue`
([Production contract](../production-contract.md)). Line numbers are at
nightly-2026-11-14. The verdicts in "Where the verdicts differ" are at
nightly-2026-11-17 (item u4moqo), the first nightly with
https://github.com/leanprover/lean4/pull/16417; what that changed is listed
there.

## Does H1 run without Std.Async and fit `Conn.step`?

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
parser's handler sends one yet, see [Production contract](../production-contract.md)).

## Cost per request

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

## Where the verdicts differ

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

## Proposal for D1 (decided: D1 in the decision record)

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
