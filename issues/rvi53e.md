Derive or check the memory bounds docs/memory.md repeats (163,880, 1,024, 81,920 bytes) once jexowc decides the allocator dependency

Left over from item 5ffu5o (values copied by hand). docs/memory.md states per-connection memory bounds (163,880; 1,024; 81,920 bytes) that Test.lean (its retained-size checks around `retainedBytes out != 81920`, about lines 857-882 and 1017-1033) and bench/boundary/main.go (`sendingBound`, about line 678) state again as literals. The 81,920 is a mimalloc size class, so whether lsrv-test may assert it is item jexowc's open question; 5ffu5o left these alone for that reason.

What the work is, after jexowc: give each bound one source (a Lean definition the tests use, the Go copy checked by lsrv-test's benchValuesAgree, the way bench/boundary's other limits now are) and have lsrv-test check the numbers docs/memory.md prints, or have the document name the definitions instead of the numbers.

Owner's choice: check the numbers in docs/memory.md mechanically, or remove them from the document in favour of naming the definitions.
