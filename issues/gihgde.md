Check zig/src/pg.c's model of a query result's Lean allocation cost against the runtime's real block sizes

Left over from item 5ffu5o (values copied by hand). zig/src/pg.c (about lines 327-386, `object_cost` and its callers) models the bytes a query result's Lean objects take, copying the Lean runtime's allocation sizes by hand. Its test, zig/src/pg_glue_test.c around line 837 (`built_cost`), computes the expected value with the same `object_cost`, so it is circular: a wrong copy of the runtime's sizes passes it.

What the work is: compare the model with the size of the blocks the runtime actually allocates for a built result (the way test/retained.c measures retained blocks), for results with several shapes (no rows, one row, many rows, NULL fields, long text fields), and fail when they differ.

Open questions for the owner:
- Measure through the allocator's own block size (mimalloc's usable size, as test/retained.c does) and accept that dependency, or through Lean's object header sizes alone?
- Does item jexowc (the mimalloc-dependent `retainedBytes` checks) decide the same question first? If so, this item waits for it.

Decided 2026-11-19 by the coordinating session with sol and hydrogen (consult round 20261119-131820-9a89; calls 2457b2df, db84fdb7) under the user's delegation to decide the next items with the models: stays Proposed until alblg3 decides the allocator dependency.

Approved by the models under the user's delegation of 2026-11-20 to decide the queue (consult round 20261120-155056-df17; sol call 421584d0, hydrogen call 69355b88), both agreeing, after alblg3: measure the real block sizes (mi_usable_size) across result shapes as the independent oracle; first check zig/src/pg.c's object_cost and its test for checks added since.

A first run (2026-11-20, report b882a6d on branch rr2/gihgde, docs/reports/result-cost-blocks.md) found mi_usable_size cannot be the oracle: mimalloc's size classes make the model neither an upper nor a lower bound (up to 24.9% under for a 32,742-byte string), and mi_good_size diverges above about 512 KiB; the +8 in object_cost is not a header under mimalloc. Decided by the models under the user's delegation of 2026-11-20 to decide the queue (consult round 20261120-164926-87db, sol and hydrogen agreeing): option A. The current Query.maxResultBytes contract stays (headers and alignment counted, allocator overhead on top); the independent oracle is the runtime's lean_object_byte_size: after building results of every shape (no rows, one, many, NULLs, long texts) the test checks that the charged cost equals the sum of aligned sizes plus 8 per object. The mi_usable_size comparison stays a measurement in the report. Correct pg.c's comment: the +8 is an explicit margin, not a header. Which results fit the limit does not change. Continue from branch rr2/gihgde (b882a6d).
