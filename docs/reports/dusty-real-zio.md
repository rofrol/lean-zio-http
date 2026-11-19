# dusty on the real zio: throughput

Measured on the M1 by item im7c5q (5a45992, 2026-11-18), one `./bench.sh`
run with dusty's stub zio and one with the real zio; the setup it measured
is described in [Modules](../modules.md), `dusty-hello/`. A historical
record, kept as it was written and not updated as the code changes; the
current contracts are in the documents
[README.md](../../README.md#documentation) lists. Item ids name queue items;
`git log --grep ID` finds their commits.

In one `./bench.sh` run each on the M1, the stub before and the real zio
after, dusty's throughput changed by 2% or less at each concurrency, while
Go, unchanged, moved by up to 6% between the same two runs; one run each
establishes no repeatable effect either way:

| dusty | c=1 req/s | c=64 req/s | c=256 req/s | CPU µs/req (1/64/256) |
|---|---|---|---|---|
| stub (watchdog) | 21,132 | 80,748 | 84,493 | 18 / 40 / 36 |
| real zio (AutoCancel) | 21,545 | 79,414 | 83,883 | 16 / 39 / 34 |
