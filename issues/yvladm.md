Decide whether per-loop PostgreSQL pools should share connections across loops

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item 63g6yu (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm bench.sh (2026-11-16): lean-db's p99 at 64 connections is 3.6 ms against Go+pgx's 2.4 ms, while throughput is 1.09 of Go's. Each loop owns `--pg-conns` connections (8 x 4 = 32) and HTTP connections spread unevenly over loops, so one loop's queue waits while another loop's slots idle (README "PostgreSQL"). Options: keep per-loop pools (no locks; current), steer accepts by pool load, or a shared pool with cross-loop handoff (locks, a new failure boundary). An architectural choice for the owner.
