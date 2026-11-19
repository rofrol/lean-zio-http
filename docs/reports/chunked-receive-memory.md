# Why the 7-byte receive row of Memory grew from 76 to 82 to 93 KiB

Measured on 2026-11-19 by item zoswdj, on the M1, at the commits named below,
each built from `git archive` with its own `lean-toolchain`. A historical
record, kept as it was written and not updated as the code changes; the
current contracts are in the documents
[README.md](../../README.md#documentation) lists. Item ids name queue items;
`git log --grep ID` finds their commits.

The question: `bench/boundary`'s scenario "memory of 100 connections holding
a nearly maximum head and all but one body byte, received 7 bytes at a time"
(the `--chunk 7` row of [Memory](../memory.md)) read 76.2 to 77.4 KiB per
connection when the row was written (commit 86a6d68, 2026-11-17), but 82 to
90 KiB in item 4bngph's runs on 2026-11-19. The suspected cause was item
p7nicw, which changed the scenario's wait to the server's `received`
reports.

## How it was measured

For each commit: `lake build lsrv-fixture` (with `LIBRARY_PATH` at
`pg_config --libdir`), `go build` in `bench/boundary`, then
`bench/boundary/boundary -only "received 7 bytes at a time"` from the tree's
root, the commits run in alternation, three or four rounds each. Each figure
is KiB of resident set per added connection, from 50 to 100 connections.

## Results

| commit | toolchain | KiB per connection |
|---|---|---|
| 86a6d68 (the row's measurement, es53kx) | nightly-2026-11-14 | 76.2, 76.5, 77.1, 76.2 |
| 8e43d30 (2kaoxd) | nightly-2026-11-14 | 76.2, 76.2, 76.2 |
| ba5ce05 (ardv3m) | nightly-2026-11-14 | 76.2, 75.5, 76.2 |
| 69c915a (ytzycm, 1/2) | nightly-2026-11-14 | 92.5, 85.4, 89.9 |
| 7b8e32a (ytzycm, 2/2) | nightly-2026-11-14 | 88.6, 89.0, 89.9 |
| b02bac9 (7mzw77, last before the toolchain move) | nightly-2026-11-14 | 85.4, 83.5, 89.3 |
| 54cef6b (u4moqo, the toolchain move) | nightly-2026-11-17 | 85.4, 89.9, 82.9 |
| a9da193 (p7nicw's parent) | nightly-2026-11-17 | 83.8, 84.2, 89.6, 84.8 |
| 291a297 (p7nicw) | nightly-2026-11-17 | 84.5, 88.6, 84.8, 85.1 |
| 7585909 (main at the item's start) | nightly-2026-11-19 | 82.2, 93.1, 87.4, 81.3 |
| 7585909 with the experiment below | nightly-2026-11-19 | 78.1, 76.5, 76.2, 75.5 |

Neither p7nicw's wait nor either toolchain move changed the row: the step is
69c915a, "Deadline expiry events in Conn.step". The rows of the same table
that receive whole (400 connections holding all but one byte of a maximum
body; 400 holding a head of 100 short fields) did not move at that commit
(73.1, 73.1 against 73.1, 73.0; 49.6, 49.7 against 49.5, 49.5).

## The cause

69c915a renamed the old `Conn.step` to `advance` and made `step` end with
`stamp s e (advance ad now s e)`. `stamp` reads `s.phase` and `s.gen` after
`advance` returns, so `s` is still live while `advance` runs: the generated
C of `step` (`.lake/build/ir/Server/Conn.c`, `lp_lsrv_Server_Conn_step___redArg`
at 69c915a) calls `lean_inc_ref` on the state before `advance`. In `advance`,
`s.buf ++ data` then appends to a shared `ByteArray` and copies it instead of
appending in place. Each receive copies the connection's whole buffer: in
this scenario about 2,300 receives of 7 bytes per connection, each copying a
buffer of up to about 16 KiB and freeing the previous one. The per-connection
resident set grows and varies more between runs (81.3 to 93.1 at main
against 75.5 to 78.1), which fits the freed blocks of many sizes leaving
pages partly used; how mimalloc's pages end up occupied was not measured.

The experiment establishes the cause: in a copy of main, `step` was given an
`@[implemented_by stepFast]`, where `stepFast` is the same function with
`s.phase` and `s.gen` read before `advance` and the generation set from those
values (the definition, and so every theorem about `step`, unchanged). Its
generated C no longer increments the state's count before `advance`, and the
row went back to 75.5 to 78.1 KiB. That copy was a measurement only; it is not
in the repository.

## What follows

The row of [Memory](../memory.md) was updated to main's figures, with this
cause. Fixing `step` so that it does not keep the state shared, and checking
what the copy costs in CPU (the `lsrv-bench` table of
[Fragmented requests](../fragmented-requests.md), measured 2026-11-17), were
proposed as a follow-up item.
