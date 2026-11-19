# Where H1's parse spends lsrv-arena's CPU

Measured on 2026-11-19 by item owgate, at commit 8bfbca5 (toolchain
leanprover/lean4 nightly-2026-11-19, the first with
https://github.com/leanprover/lean4/pull/16562), on the M1 and in
`linux/Dockerfile`'s Debian container on the M1's OrbStack (arm64). A
historical record, kept as it was written and not updated as the code
changes; the current contracts are in the documents
[README.md](../../README.md#documentation) lists. Item ids name queue items;
`git log --grep ID` finds their commits.

The question came from [the over-5 s tail](over-5s-tail.md), "What a
pipelined response costs": `H1Adapter.Parser.parse` took 41 % (pipelined)
and 39 % (baseline) of lsrv-arena's CPU samples, about 3.8 and 5.9 µs per
request. Scope (decided with the item): local profiling only, no load run;
feeding H1 a slice only if its documented contract allows it; anything
inside `Std.Http` follows AGENTS.md, Rule 6.

## How it was measured

`lsrv-parsebench` ([running](../running.md)) runs HttpArena's request shapes
through the adapter's parses of each receive (`parse`: a new `Parser` on the
buffer, then on the bytes after each request, as `Conn.serve` does) and
through `Conn.step` with `App.Arena` (`step`). `bench/parse/profile.sh`
recorded call-graph profiles of one loop: Instruments' Time Profiler on the
M1 (1 ms samples), `perf record -g -F 999` in the container. The shares
below are inclusive shares of all of the program's samples (the measured
loop is over 99.9 % of them), split by caller and callee from the exported
backtraces. Paths of `Std` are under the toolchain's `src/lean/Std/`.

| profile | samples | ns per request (the run's row) |
|---|---|---|
| M1, pipelined parse, 2,000,000 receives | 87,458 | 2,738 |
| Linux, pipelined parse, 1,000,000 receives | 42 K | 2,633 |
| M1, baseline-get parse, 3,000,000 receives | 11,886 | 3,965 |
| M1, pipelined step, 300,000 receives | 17,806 | 3,739 |

`lsrv-parsebench` with no arguments on the M1 (median of five runs):

| shape | level | ns per request | small allocations per request |
|---|---|---|---|
| baseline-get | parse | 3,973 | 189 |
| baseline-get | step | 5,809 | 241 |
| baseline-post | parse | 5,117 | 241 |
| baseline-post | step | 7,113 | 302 |
| pipelined | parse | 2,712 | 130 |
| pipelined | step | 3,661 | 155 |

At the `step` level (pipelined) the parse is 71 % of lsrv-arena's Lean side
(`Parser.parse` inclusive 12,683 of 17,806 samples); the rest is the
response's rendering and the connection's bookkeeping.

## Where the parse goes

Inclusive shares of the pipelined parse loop (`GET /pipeline HTTP/1.1`,
`Host: 127.0.0.1:8080`), M1 and Linux; baseline-get
(`GET /baseline11?a=13&b=42`, `Host: localhost:8080`) on the M1 in the last
column. The rows overlap where noted.

| where (Std.Http unless said) | M1 | Linux | baseline-get |
|---|---|---|---|
| `H1Adapter.Parser.parse`, all | 94.0 % | 94.8 % | 94.3 % |
| request line (`processReceivingStartLine`) | 29.3 % | 29.4 % | 38.7 % |
| of it, the request-target (`URI.Parser.parseRequestTarget`) | 9.9 % | 9.8 % | 22.4 % |
| field lines' syntax (`parseSingleHeader`) | 18.7 % | 19.9 % | 12.9 % |
| field names and values typed (`processParsedHeader`: `Header.Value.ofString?`, `Header.Name.ofString?`) | 11.3 % | 11.1 % | 8.0 % |
| head checks (`checkReceivingMessageHead`) | 16.0 % | 16.1 % | 21.4 % |
| of it, the Host value parsed again as a URI host (`Header.Host.parse`) | 13.4 % | 13.5 % | 19.8 % |
| the adapter's `drainBody` (H1's `pullBody` on an empty body) | 5.6 % | 5.7 % | 4.3 % |
| the adapter's own code (`Parser.parse`'s self samples) | 2.2 % | 2.3 % | 1.6 % |

So about nine tenths of the parse is H1's own work in `Std.Http`; the
adapter's own code is about 2 % of the samples, and the per-request copy of
the buffer's rest (`lean_byte_array_copy_slice` called from `Parser.parse`)
0.7 % on the M1. At the `step` level `Conn.serve`'s own extract adds 0.3 %.

By function (self samples), the runtime's allocator and reference counting
take the largest share, spread over every parser above: on the M1 `mi_free`
15.7 %, `lean_dec_ref_cold` 10.3 %, `_tlv_get_addr` 7.1 % (macOS's
thread-local lookup inside `lean_alloc_small_object_core`; absent on Linux),
`lean_alloc_small_object_core` 4.4 %, `mi_malloc` 2.6 %; on Linux `mi_free`
14.5 %, `lean_alloc_small_object_core` 11.2 %, `lean_dec_ref_cold` 11.1 %,
`mi_malloc` 2.6 %. That matches 130 small allocations for a 48-byte
pipelined request and 189 for baseline-get's 58 bytes.

What the hot spots are, read in the source:

- `Std.Internal.Parsec.ByteArray.scanWhileUpTo` (Internal/Parsec/ByteArray.lean:233),
  under every `takeWhileUpTo` of the field lines, the URI and the Host, is a
  `private partial def` that takes the predicate as a closure: 7.7 % self
  (Linux 7.6 %), plus `lean_apply_1` 5.8 % (Linux 5.5 %, of it 4.2 % called
  from `scanWhileUpTo`), one closure call per byte scanned.
- The Host value is checked by `hasSingleAcceptedHostHeader`
  (Protocol/H1.lean:296) through `Header.Host.parse`, which runs
  `URI.Parser.parseHostHeader` (Data/URI/Parser.lean:482): `parseHost`
  decodes the name, tries an IPv4 literal (`Net.IPv4Addr.ofString`, which
  reaches libuv's `inet_pton4`, 1.2 % for `127.0.0.1`), lower-cases it and
  decides `URI.IsValidDomainName` at run time (`URI.endsInNumber` 4.6 % and
  a well-founded loop specialized in `parseHost` 4.9 % of baseline-get, for
  `localhost`). That is 0.36 µs of a pipelined
  request's 2.7 and 0.78 µs of a baseline-get's 4.0.
- Field values are scanned as bytes by `parseFieldLine`, then turned into
  `String`s and checked again character by character
  (`Header.Value.ofString?`, `String.Slice.Pos.skipWhile`, 3.0 % self, and
  `String.Slice.trimAscii`).
- Byte slices are copied into new `ByteArray`s (`ByteSlice.toByteArray`,
  3.9 % inclusive on the M1), and `String.fromUTF8Lossy` and `lean::utf8_strlen` run
  on parsed parts.

## What follows

- The 40 % is H1's own parse of each head, not a re-parse of the buffer and
  not the adapter's copy: the copy is under 1 % of the parse loop's samples.
- Feeding H1 a slice or an offset instead of the copy is not available
  within H1's contract and would not pay: `Machine.feed`
  (Protocol/H1.lean:955) takes a `ByteArray`, and no documented entry takes
  a slice or a start offset (`Reader.feed`, Protocol/H1/Reader.lean:182,
  takes the array as the new input when the old one is used up, as it is in
  a fresh machine); the copy it would remove is 0.7 % of the samples.
- The costs in `Std.Http` are not bugs under AGENTS.md, Rule 6: no
  performance contract that this behavior violates was found in the
  docstrings and comments of `Std/Http/` and `Std/Internal/Parsec/`
  (searched for "performance", "complexity", "O(n)", "zero-copy"; the one
  hit, H1/Writer.lean:125, is about the writer), and the work is H1's
  validation of the head, which the adapter relies on (the checks
  `Server/H1Adapter.lean`'s header lists). Making them cheaper is an upstream
  performance change (specializing `scanWhileUpTo` on its predicate,
  checking the Host value without a second URI parse, not re-checking field
  values the field-line parser already scanned, fewer allocations), which
  needs an issue or PR to leanprover/lean4 and so the owner's go; this item
  proposes it as a separate item with the option of accepting the cost.
- No change to this repository's code follows from the profile.

## Anomalies met

`perf report` wrote 168,206 lines of "unwind: get_proc_name unsupported" for
its two reports of 42 K samples (about two per sample in each report), where
`bench/parse/profile.sh`'s header says one per few samples. It does not
bear on the shares above: in `linux-children.txt` 99.99 % of the samples have
their whole chain up to `_lean_main`, and the Linux shares agree with the
M1's (Instruments, no such messages) within 1.2 points in every row.
