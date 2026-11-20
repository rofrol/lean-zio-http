Check zig/src/pg.c's model of a query result's Lean allocation cost against the runtime's real block sizes

Left over from item 5ffu5o (values copied by hand). zig/src/pg.c (about lines 327-386, `object_cost` and its callers) models the bytes a query result's Lean objects take, copying the Lean runtime's allocation sizes by hand. Its test, zig/src/pg_glue_test.c around line 837 (`built_cost`), computes the expected value with the same `object_cost`, so it is circular: a wrong copy of the runtime's sizes passes it.

What the work is: compare the model with the size of the blocks the runtime actually allocates for a built result (the way test/retained.c measures retained blocks), for results with several shapes (no rows, one row, many rows, NULL fields, long text fields), and fail when they differ.

Open questions for the owner:
- Measure through the allocator's own block size (mimalloc's usable size, as test/retained.c does) and accept that dependency, or through Lean's object header sizes alone?
- Does item jexowc (the mimalloc-dependent `retainedBytes` checks) decide the same question first? If so, this item waits for it.

Decided 2026-11-19 by the coordinating session with sol and hydrogen (consult round 20261119-131820-9a89; calls 2457b2df, db84fdb7) under the user's delegation to decide the next items with the models: stays Proposed until alblg3 decides the allocator dependency.

Approved by the models under the user's delegation of 2026-11-20 to decide the queue (consult round 20261120-155056-df17; sol call 421584d0, hydrogen call 69355b88), both agreeing, after alblg3: measure the real block sizes (mi_usable_size) across result shapes as the independent oracle; first check zig/src/pg.c's object_cost and its test for checks added since.
