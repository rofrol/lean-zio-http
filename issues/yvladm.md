Decide whether per-loop PostgreSQL pools should share connections across loops

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item 63g6yu (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm bench.sh (2026-11-16): lean-db's p99 at 64 connections is 3.6 ms against Go+pgx's 2.4 ms, while throughput is 1.09 of Go's. Each loop owns `--pg-conns` connections (8 x 4 = 32) and HTTP connections spread unevenly over loops, so one loop's queue waits while another loop's slots idle (README "PostgreSQL"). Options: keep per-loop pools (no locks; current), steer accepts by pool load, or a shared pool with cross-loop handoff (locks, a new failure boundary). An architectural choice for the owner.

Question: Should the PostgreSQL pools stay per loop, steer accepts by pool load, or become one shared pool with cross-loop handoff?
Options: keep per-loop pools until imbalance evidence from the Linux runs | steer accepts by pool load | a shared pool with cross-loop handoff
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.

Checked 2026-11-17 with sol (consult round 20261117-011832-74e7) under the user's delegation: deferred: keep per-loop pools until Linux runs (53rwgc) correlate per-loop queueing, occupied slots and latency; aggregate p99 alone does not show imbalance.

Decided 2026-11-18 by the coordinating session with sol, argon and hydrogen (consult round 20261118-181941-5f8f; calls 4a23f520, e4c9a8ea, 272fc555), under the user's delegation of 2026-11-18 to decide the remaining open questions with the models: deferred (all three agree): keep per-loop pools. Reopen when a Linux run after sakmfp correlates per-loop queueing, occupied slots and tail latency (requests queued on a loop with every slot busy while another loop has idle slots); aggregate p99 is not enough. If confirmed, try steering accepts by pool load before a shared pool.
