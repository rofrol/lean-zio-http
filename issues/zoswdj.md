Explain why bench/boundary's 7-byte nearly-maximum-head row measures 82 to 89 KiB against the 76.2 to 77.4 KiB in docs/memory.md

Seen while doing item 4bngph (lean-zio-http, branch rr2/4bngph), 2026-11-19, M1.

The scenario "memory of 100 connections holding a nearly maximum head and all but
one body byte, received 7 bytes at a time" (bench/boundary/main.go, the
`--chunk 7` row of the table in docs/memory.md, line 154: "76.2 to 77.4",
measured 2026-11-17) now reads 82.2 KiB (./bench.sh on the item's final
tree), and 83.2 to 88.0 KiB in the earlier runs of the item. The same tree
built under the old toolchain (nightly-2026-11-17, HEAD dd9b28e via git
archive) gave 84.5 to 89.6 KiB, so the toolchain move did not cause it. The
row's wait changed on 2026-11-19 (item p7nicw: `awaitRead` on the server's
`received` reports instead of the socket queues); the most likely cause is
that the new wait measures after Lean has taken every receive, which the old
one did not ensure, but that is not established.

Proposed work: run the row at p7nicw's parent and at p7nicw (same toolchain)
to confirm or refute that the wait change moved it, then update the row and its
note in docs/memory.md with the cause; if neither commit moves it, trace further.
The row checks no bound ("a measurement; no bound"), so nothing fails today.
