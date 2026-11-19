Check zig/src/pg.c's model of a query result's Lean allocation cost against the runtime's real block sizes

Left over from item 5ffu5o (values copied by hand). zig/src/pg.c (about lines 327-386, `object_cost` and its callers) models the bytes a query result's Lean objects take, copying the Lean runtime's allocation sizes by hand. Its test, zig/src/pg_glue_test.c around line 837 (`built_cost`), computes the expected value with the same `object_cost`, so it is circular: a wrong copy of the runtime's sizes passes it.

What the work is: compare the model with the size of the blocks the runtime actually allocates for a built result (the way test/retained.c measures retained blocks), for results with several shapes (no rows, one row, many rows, NULL fields, long text fields), and fail when they differ.

Open questions for the owner:
- Measure through the allocator's own block size (mimalloc's usable size, as test/retained.c does) and accept that dependency, or through Lean's object header sizes alone?
- Does item jexowc (the mimalloc-dependent `retainedBytes` checks) decide the same question first? If so, this item waits for it.
