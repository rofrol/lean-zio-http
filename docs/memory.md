# Memory

Three kinds of statement, kept apart: lengths that `Conn.step_inv` proves,
allocations derived from the code of the runtime and its allocators (for the
adapter's state also checked against the blocks a state actually holds), and
resident set growth that `bench/boundary` measures. A connection holds at
most 317,610 bytes (310.2 KiB) of live blocks besides its small Lean
objects, half of them H1's parsed request-target while a request is
incomplete (below): 1.21 GiB at the default 4,096 connections. This replaces
the 715,228 bytes (698.5 KiB) derived before the adapter limited the
target's path segments and query parameters (2026-11-19), which replaced the
statement of about 98 KiB per connection, withdrawn when the adapter's state
was measured.

**Lengths** (proved, `Conn.step_inv`): the Lean buffer of unconsumed bytes
holds at most `inCap` = 16,388 bytes and a response being sent at most
`maxResponseBytes` = 65,536.

**Allocations** (derived; toolchain nightly-2026-11-14, its runtime at
lean4 commit 62e0cf0, mimalloc 3.4.5; a block size is what the toolchain's
`mi_good_size` returns for the object, on the M1). Rechecked for
nightly-2026-11-17 (lean4 commit 55069db): `src/runtime/object.cpp`,
`object.h`, `alloc.cpp` and `lean.h` are unchanged, mimalloc is still 3.4.5,
and `lsrv-test` measures the same bytes for every retained-state case.
Rechecked for nightly-2026-11-19 (lean4 commit 8009d0a): `object.cpp` and
`lean.h` change only `Nat` shifts and the panic of an out-of-bounds borrowed
array read, `object.h` and `alloc.cpp` are unchanged, mimalloc is still
3.4.5, and `lsrv-test` measured the same bytes for every retained-state case
of nightly-2026-11-17 before the cases changed with the limits below:

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
  is a 65,536-byte block. Responses to pipelined requests sent together
  (`Conn.batch`) are copied into one array allocated with capacity exactly
  their total, which is at most 65,536, so the same bound holds (`lsrv-test`
  checks a batch of exactly 65,536 bytes: one 81,920-byte block); the
  separate responses are dropped within the step.
- The adapter's initial state is one object shared by every connection
  (H1's is a closed term, `lean_obj_once` in the generated C), so a
  connection whose adapter is at `init` holds none of its own; the interim
  `100 Continue` is a shared constant too.

So a connection holds, besides its small Lean objects (the state, phase and
action constructors, tens of bytes each):

- while reading, and while sending the interim response: at most 20,480 +
  40,960 = 61,440 bytes, plus the adapter's state, with H1 at most 256,170
  (below): 317,610 bytes (310.2 KiB) in all, the most of any state;
- while sending a final response: at most 20,480 + 10,240 + 81,920 =
  112,640 bytes (110 KiB), the adapter at `init`;
- while waiting for a query: the connection and an exact buffer of under
  8,192 bytes, plus the `Server.Query` and continuation the handler built
  (bounded by what it builds), and while the continuation turns it into the
  answer a result whose Lean value costs at most `Query.maxResultBytes`
  (counted with object headers; libpq's buffers are the pool session's,
  [PostgreSQL](postgresql.md), "Bounded only in part").

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
  kept in the message head until the request completes: at most 159,606.
  `H1Adapter.config` allows at most `maxPathSegments` = 255 path segments
  and `maxQueryParams` = 1,000 query parameters, empty ones counted (the
  sources of both values are next to them in `Server/H1Adapter.lean`); H1
  answers a target with more with 414, as one over `maxUriLength`
  (`exceedsElementLimits` in `Std/Http/Protocol/H1/Parser.lean`, lean4 PR
  16562, since nightly-2026-11-19). Without them a `maxUriLength` target
  could hold an element per byte, 557,224 bytes of blocks. A block holding
  an object of `x` bytes is at most `x + x/4 + 7`. A segment is a
  `ByteArray` of its bytes: at most 37 bytes plus 5/4 of its bytes. A
  parameter is a 24-byte pair of its key and, after `=`, a 16-byte `some`
  of its value, each such a `ByteArray`: at most 114 plus 5/4 of its bytes
  (the pair and the `some` take blocks of exactly their size: `mi_good_size`
  of 16 and 24 is 16 and 24, as of every multiple of 8 up to 64, measured
  against the toolchain's `libleanshared`).
  The other parts of an absolute-form target are at most five strings, 49
  each plus 5/4 of their bytes, and the bytes of all parts together at most
  `maxUriLength` = 8,192. The arrays of segments and parameters have
  capacity at most twice their size (`lean_copy_expand_array`), 8 bytes a
  slot after a 24-byte header, and the target's own constructors take 512:
  37 × 255 + 114 × 1,000 + 5 × 49 + 10,240 + 5,137 + 20,037 + 512;
- the header fields: at most `maxHeaders` = 100 pairs of a name and a value
  string, whose bytes total at most `maxHeadBytes`: at most 34,076;
- the constructors of the parser, machine, reader, writer and head: at most
  1,024.

In all at most 256,170 bytes (250.2 KiB). What a parse allocates and drops
within a step (the target's split into strings, a field line, and a target
over the limits, which H1 parses whole before it counts its elements) is per
loop, not per connection (above). `lsrv-test` checks each part against the blocks
the state actually holds (`test/retained.c` walks the state's objects and
adds `mi_usable_size` of each block, a shared one once, the persistent
initial state not at all) in every incomplete state of requests that drive
each part toward its bound, fed whole and in pieces of 7 and 1,460 bytes; the
largest is 126,488 bytes, with a request line of 8,192 bytes whose
absolute-form target has user info, a port, 255 empty segments and 1,000 parameters, the most
the limits allow, 999 of them with empty values and the rest of the line in
the last one's value (H1 keeps the target from the end of the line, before
any field); in origin-form, 126,168. These cases stress the bound, they do
not attain it. `lsrv-test` also checks that a target with 255
segments or 1,000 parameters is served and one with 256 or 1,001 gets 414. The arithmetic depends on the runtime (object
layouts, array growth, mimalloc's block sizes): that check, run at each
toolchain update, shows whether these cases still fit it, which is evidence
for the arithmetic, not a proof of it. It bounds live blocks; how much is resident,
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
| a head of 97 fields of 72-byte values and all but one body byte, received 7 bytes at a time (`--chunk 7`) | 100 | 81.3 to 93.1 |
| an incomplete request after 50 pipelined ones | 400 | 31.4 to 32.1 |
| a head whose request-target has 255 path segments | 400 | 51.9 |
| a head whose request-target has 1,000 query parameters | 400 | 104.6 to 105.1 |
| a request line whose origin-form target has 255 empty segments and 1,000 parameters, the most the limits allow, 999 with empty values and the rest of the line in the last, after a complete request | 400 | 167.0 to 167.2 |
| a 60,121-byte response being sent, with a pipelined tail buffered | 100 | 90.6 |

(Four runs each, 2026-11-17; earlier runs of the first and last rows gave
52.0 and 90.6 to 90.9. The three rows of the request-target: four runs each,
2026-11-19, toolchain nightly-2026-11-19, with the limits; before them, a
head of 4,000 path segments grew it by 207.8 to 208.0 KiB, one of 4,000
query parameters by 301.8 to 301.9, and a request line of 8,176 empty query
parameters by 500.7 to 501.0. The row of 7-byte receives: four runs,
2026-11-19, toolchain nightly-2026-11-19; it read 76.2 to 77.4 when first
measured, 2026-11-17, and grew because `Conn.step` keeps the connection's
state shared while `advance` runs, so each receive copies the whole buffer
instead of appending in place; with that copy removed the same tree measured
75.5 to 78.1. The rows that receive whole did not move:
[the report](reports/chunked-receive-memory.md).) For the line with the most elements the
limits allow, the adapter's state holds 126,168 bytes (123.2 KiB) of live
blocks (`lsrv-test`), besides the connection's 20 KiB and its buffer; with
the hand-written parser, which keeps no state, the same connections grew the
resident set by 41.7 KiB each.
The interim response shows that a connection
holds its head; for a body or a request line, the server, started with
`--report-recv`, prints `received <bytes>` once Lean's state has taken each
receive, and the scenario waits until those add up to every byte its
clients wrote (`awaitRead`, since 2026-11-19, item p7nicw): the rows of the
request line and of 7-byte receives, 2026-11-19. The row of a whole body, run
2026-11-17, waited instead until the socket queues (lsof on macOS, `/proc` on
Linux) showed every byte taken from the sockets, which did not exclude a
receive not yet handed to Lean; for the row of 7-byte receives the change of
wait made no measurable difference (p7nicw and its parent on the same
toolchain: 84.5 to 88.6 and 83.8 to 89.6). At
4,096 connections, connections holding the request line with the most
elements would take about 668 MiB resident (2.0 GiB before the limits).

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
2026-11-18) the scenario ran on epoll and io_uring: 85.0 to
88.0 KiB per added connection with either parser (twenty runs), Lean's
mimalloc arena 68 to 71 KiB of it and glibc's malloc 17 KiB
(`/proc/PID/smaps`). `bench/boundary` turns transparent huge pages off for
itself and the servers it starts (`disableTHP`, checked before each
resident set sample): with them on (the host's `madvise`), the arena grew
in 2 MiB steps, 41 KiB per connection over the 50 added, and the scenario
read 58 or 99 KiB. The memory scenarios measure what a connection holds
under base pages, not the resident set of a server with huge pages, which
can hold memory in 2 MiB units. This scenario is skipped on systems other
than macOS and Linux (and so, until 2026-11-19, were the three that waited
on the socket queues). Those three ran on Linux too (the same
container, one run per backend, 2026-11-18), per added
connection with H1 on epoll and io_uring: 51.9 and 51.8 KiB holding all but
one byte of a maximum body, 60.9 and 70.2 KiB for the nearly maximum head
received 7 bytes at a time, 495.6 and 483.2 KiB for the request line with
8,176 query parameters (28.9 and 28.8 KiB with the hand-written parser).
With the target's limits (the same container, one run per backend,
2026-11-19, nightly-2026-11-19), on epoll and io_uring: 152.4 and 152.3 KiB
for the request line with the most elements the limits allow (29.0 and
28.8 KiB with the hand-written parser), 34.7 and 34.6 KiB for a head of 255
path segments, 87.5 and 87.3 KiB for one of 1,000 query parameters.
