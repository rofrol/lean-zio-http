Bound the capacity of connection buffers or qualify the memory claim

Split from byurlg on 2026-11-16 (consult round 20261116-145342-a8e2): Conn.step_inv bounds the lengths of the byte arrays, not their capacities; an array grown by appending can hold about twice its length.
Question: Should buf and out be allocated at fixed capacity and kept unshared, or should the README's memory bound be stated as about twice the lengths?
Options: qualify the claim first from verified allocation behavior | allocate at fixed capacity
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.

Decided 2026-11-17 by the coordinating session with sol (consult round 20261117-011832-74e7), under the user's delegation of the same day to decide the open questions with sol: qualify the claim from verified allocation behavior: check the arrays' capacity growth and correct the README and the benchmark accounting, keeping proven length bounds apart from allocated and resident measurements; no 'about twice' without evidence. Includes msr26a (restate the bound from allocated block sizes; Conn is not shrunk). No fixed-capacity redesign now.

From msr26a (merged 2026-11-17): the loop's connection is a 16,712-byte Conn (@sizeOf, Zig 0.17.1; zig/src/serve.zig alloc.create(Conn), std.heap.c_allocator) that heap -s shows as a 20,480-byte block; the malloc zone grows 21.1 KiB resident per added connection. The stated bound and perConnBound in bench/boundary/main.go (memory, memoryFull) count 16,640 bytes for it, and the 2 KiB allocator allowance does not cover the block's 3.8 KiB size-class excess. A further 2.9-3.9 KiB per connection is an unattributed residual in Lean's mimalloc region (item xlto7s, README "Memory", bench/boundary -memsnap, M1, nine runs).

From sxrhgm (merged 2026-11-17, Decided 2026-11-17 by the coordinating session with sol (consult round 20261117-025619-5ef1), under the user's delegation of the same day):

Bound or measure the worst case of the adapter state a connection retains

Seen while doing daaqgn (commit a7d6c0b). `Conn.State.parser` (the H1 machine with the parsed head, its unread input and the body pulled so far) is retained per connection while a request is incomplete. `Conn.step_inv` does not bound it (Conn is generic over σ), and README "Memory" now says so: the 98 KiB per-connection bound leaves it about 64 KiB, and the only measurement is a held 8,000-byte head (`bench/boundary`: 52.0 KiB per connection, was 42.4). Not measured: `maxHeaders` (100) short fields, a body of nearly `maxBodyBytes` pulled before its last byte, small fragments, an incomplete request after pipelined ones. Proposal: add those `bench/boundary` scenarios against the 98 KiB bound, or state a size law for adapters that Conn's memory theorem can use. Raised by the consult review (sol) of daaqgn.

Scope added to this item: add the four boundary scenarios (100 short header fields, a nearly complete maximum body, small fragments, an incomplete request after pipelined ones) and account for allocations retained at the same time. Measurements can only falsify the 98 KiB claim; the bound counts as established only when derived from allocations, adapter state included.
