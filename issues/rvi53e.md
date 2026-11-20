Derive or check the memory bounds docs/memory.md repeats (163,880, 1,024, 81,920 bytes) once jexowc decides the allocator dependency

Left over from item 5ffu5o (values copied by hand). docs/memory.md states per-connection memory bounds (163,880; 1,024; 81,920 bytes) that Test.lean (its retained-size checks around `retainedBytes out != 81920`, about lines 857-882 and 1017-1033) and bench/boundary/main.go (`sendingBound`, about line 678) state again as literals. The 81,920 is a mimalloc size class, so whether lsrv-test may assert it is item jexowc's open question; 5ffu5o left these alone for that reason.

What the work is, after jexowc: give each bound one source (a Lean definition the tests use, the Go copy checked by lsrv-test's benchValuesAgree, the way bench/boundary's other limits now are) and have lsrv-test check the numbers docs/memory.md prints, or have the document name the definitions instead of the numbers.

Owner's choice: check the numbers in docs/memory.md mechanically, or remove them from the document in favour of naming the definitions.

Decided 2026-11-19 by the coordinating session with sol and hydrogen (consult round 20261119-131820-9a89; calls 2457b2df, db84fdb7) under the user's delegation to decide the next items with the models: stays Proposed until alblg3 decides the allocator dependency.

Approved by the models under the user's delegation of 2026-11-20 to decide the queue (consult round 20261120-155056-df17; sol call 421584d0, hydrogen call 69355b88), both agreeing, after alblg3: check the numbers mechanically (or name their definitions instead of repeating them), keeping the Go agreement check.
