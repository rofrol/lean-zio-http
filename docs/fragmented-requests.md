# Fragmented requests (decision D1)

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
local workaround of the parser). The memory bounds of [Memory](memory.md) hold for any
split, since the buffer never exceeds `inCap`.
