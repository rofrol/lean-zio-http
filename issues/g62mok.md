Decide whether to measure the pool's readiness probe (peek against NetPoll) on Linux

Found by item jexowc (docs/reports/dependency-assumptions.md, point 4; docs/reports/postgresql-throughput.md, section "2026-11-19: the peeking receive against NetPoll"). On the shared M1 the pool's one-byte MSG_PEEK receive (zig/src/pg.zig:192-202) cost lsrv-db less CPU per request than zio's NetPoll (medians 40.6 against 50.3 µs at c=64, 8 of 8 interleaved rounds), consistent with macOS poll(2) on an empty socket costing about 7.5 µs against 0.26 µs for the receive. In the Linux container (OrbStack, aarch64, AF_UNIX) the two syscalls cost about the same (151-158 against 145-156 ns), and on kqueue/epoll a parked peek costs two receives against NetPoll's one poll(2) (zio src/ev/sockreg.zig:431-450, 276-315), so on Linux, where production runs, NetPoll might cost less; on io_uring NetPoll is a POLL_ADD. No server comparison was run on Linux.

Options considered: run the same A/B (two lsrv-db builds differing only in `Slot.rpoll`) with bench/dbpairs.sh's method in the Linux container and on the VPS, and choose the probe per backend from it | keep the peek everywhere and record that Linux was not measured | do nothing now.

Decided 2026-11-19 by the coordinating session with sol and hydrogen (consult round 20261119-131820-9a89; calls 2457b2df, db84fdb7) under the user's delegation to decide the next items with the models: needs the owner (VPS load).
Question: How much Linux evidence for the pool's peek against NetPoll?
Options: container A/B only, then decide | container and VPS A/B (your go for VPS load) | keep peek and note Linux unmeasured
