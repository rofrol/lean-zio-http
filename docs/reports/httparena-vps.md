# HttpArena on the VPS

Measured on 2026-11-18 by item dtlin3 on vps.frolow.dev, the production
host, with lsrv-arena built from 2ae7e98 (the accept fix, item sakmfp, is
caeba5f); it replaced item 53rwgc's run of 2026-11-17 (3ce9bdc). A
historical record, kept as it was written and not updated as the code
changes; the current contracts are in the documents
[README.md](../../README.md#documentation) lists. Item ids name queue items;
`git log --grep ID` finds their commits.

**These figures are a diagnostic, not a clean acceptance of ekklesiai.org's
speed requirement D2.** The load generator ran on the same 2 vCPUs as the
server, as the owner approved for these runs (2026-11-17, and under the
owner's delegation of 2026-11-18 for this rerun): throughput is a lower
bound, and latency and CPU per response are observations contaminated by
the generator. A clean D2 acceptance needs the generator on cores of its
own.

The figures below are item dtlin3's rerun (2026-11-18), after the accept
fix (item sakmfp). They replace item 53rwgc's (2026-11-17), which were
invalid for lsrv-arena: its transport then accepted one connection per loop
turn, so about half of the 4,096 connections were not served during a
sample and gcannon's figures covered only the others ([The over-5 s tail](over-5s-tail.md)). git history keeps that run's tables.

What ran: HttpArena (https://github.com/MDA2AV/HttpArena, da3ded60952b) at
its HTTP/1.1 profiles this server owns, on vps.frolow.dev, the production
host (2026-11-17: x86_64, 2 vCPU Intel Xeon Gold 6152, 2.4 GB of memory,
kernel 6.12.74+deb13+1-amd64, Debian 13.4), with lsrv-arena (`MainArena.lean`,
`App/Arena.lean`: HttpArena's `/baseline11` and `/pipeline` as its go-stdlib
entry answers them) on epoll and on io_uring, built from main at 2ae7e98
(the accept fix is caeba5f; item dtlin3 changed only `bench/`), against
HttpArena's go-stdlib (the floor) and go-fasthttp (the target) entries. Five
rounds after one warm-up round, the contenders' order rotating each round,
a fresh server per sample. Versions: Lean nightly-2026-11-17, Zig 0.17.1,
zio 53ed3c377317, gcannon fb63bf61387314 (liburing 2.9) with
`bench/arena/gcannon-served.patch`, zrk 2.3.0, Go 1.27.3 for the Go entries.
lsrv-arena runs 2 loops with `--max-conns 16384`.

How (`bench/arena/`): `build.sh` cross-builds everything for x86_64 Linux on
the M1 (nothing is built on the host, whose disk is shared and nearly
full), and `run.sh tests|bench|db`, run as root on the host from the copied
directory (`/var/tmp/lsrv-arena-dtlin3`), runs it in a transient systemd
scope of its own (900 MB of memory, no swap) and fresh network and PID
namespaces (`inner.sh`), watching the site's health URL once a second and
ending the run at the first answer other than 200 or slower than 1 s.
`summarize.py` prints the tables below from the copied `out/` directory.
`run.sh db` runs `bench/dbpairs.sh` there ([PostgreSQL measurements](postgresql-throughput.md)).

Deviations from HttpArena's own run, all applied to every contender alike:
- Native processes in namespaces instead of HttpArena's docker containers,
  CPU pinning and host networking, and the generators with 2 threads
  (HttpArena's defaults assume a 64-core machine).
- baseline and limited-conn send HttpArena's GET and Content-Length POST
  templates, without its chunked POST: this server answers chunked request
  bodies 501 ([Production contract](../production-contract.md), "Not yet"), so HttpArena's validation check "POST
  /baseline11 chunked" fails for lsrv-arena. Every other check passes for
  every contender: the sums, a random sum, Content-Type, `/pipeline`, and
  16 requests pipelined on one connection.
- gcannon carries `gcannon-served.patch`, which only counts: its report
  gains "Connections served", the connection slots answered at least once
  in the measured window (after the warm-up). It is how this run counts the
  connections served, against the 4,096 configured; the host has no
  tracing tools, and the local diagnostic
  ([The over-5 s tail](over-5s-tail.md)) traced accepts instead.
- Left out: async (each request answered after 10 ms: the handler has no
  timer, `Request → Await Response` waits only for queries, and adding one
  changes the architectural core), so memory under async is not measured;
  latency-1m (a million connections do not fit the host); and the profiles
  this server does not own (TLS, HTTP/2 and 3, compression, static files,
  databases, WebSocket).

The test suite on the host itself, before the runs: `zig build test`'s
binaries for x86_64 (from `build.sh`) passed on epoll and on io_uring each:
serve_test's 42 tests, pg_test's 38, and pg_glue_test.

Results, rounds 1-5: median (min-max) per sample; req/s counts 2xx responses
over the generator's window; CPU per response is the server's user and
system time over the whole generator run (connection set-up included)
divided by its responses; peak MB is the sample's own server's VmHWM. A
difference is resolved only where the ranges do not overlap. Every response
of every sample was 2xx (gcannon's status counts equal its responses), and
zrk reported no error. "over 5 s" counts responses slower than 5 s
(gcannon's latency overflow, outside its histogram, so its percentiles
leave them out); "served" is the patch's count of connections answered
in the window, of 4,096 (in limited-conn, connection slots, each reopened
after 10 requests, `-r 10`).

baseline (gcannon, 4096 connections, 5 s, GET and POST alternating):

| server | runs | req/s | p99 ms | p99.9 ms | CPU µs/resp | peak MB | non-2xx | over 5 s | served |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lsrv-epoll | 5 | 23,467 (22,246-25,189) | 847.9 (785.4-937.3) | 1480 (1410-1640) | 61 (57-63) | 84 (84-85) | 0 | 0 | 4,096 in each |
| lsrv-io_uring | 5 | 23,531 (21,626-25,709) | 588.9 (513.3-651.5) | 856 (753-909) | 61 (55-65) | 86 (84-86) | 0 | 0 | 4,096 in each |
| go-stdlib | 5 | 24,807 (24,209-29,147) | 1170.0 (596.1-1580.0) | 1510 (1290-2540) | 56 (47-57) | 141 (136-142) | 0 | 0 | 4,096 in each |
| go-fasthttp | 5 | 40,841 (38,047-43,383) | 299.6 (258.8-392.1) | 512 (457-710) | 27 (26-30) | 82 (82-83) | 0 | 0 | 4,096 in each |

pipelined (gcannon, 4096 connections, 16 requests in flight on each, 5 s):

| server | runs | req/s | p99 ms | p99.9 ms | CPU µs/resp | peak MB | non-2xx | over 5 s | served |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lsrv-epoll | 5 | 34,799 (32,016-35,920) | 3220 (2980-3580) | 3720 (3360-4120) | 37 (37-41) | 87 (86-89) | 0 | 0 | 4,096 in each |
| lsrv-io_uring | 5 | 35,492 (28,831-37,913) | 3070 (2830-3860) | 3570 (3250-4360) | 37 (34-46) | 87 (87-89) | 0 | 0 | 4,096 in each |
| go-stdlib | 5 | 42,108 (34,962-45,379) | 4460 (4020-4770) | 4710 (4390-4910) | 35 (31-40) | 73 (63-82) | 0 | 169 | 1,788 (1,463-2,118) |
| go-fasthttp | 5 | 421,898 (306,909-441,098) | 601.5 (373.6-911.2) | 976 (669-1490) | 3 (3-4) | 80 (79-83) | 0 | 0 | 4,096 in each |

limited-conn (baseline with a new connection after every 10 requests):

| server | runs | req/s | p99 ms | p99.9 ms | CPU µs/resp | peak MB | non-2xx | over 5 s | served |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lsrv-epoll | 5 | 23,113 (21,794-24,786) | 920.2 (836.5-970.2) | 1320 (1220-1440) | 60 (56-64) | 72 (68-74) | 0 | 0 | 4,096 in each |
| lsrv-io_uring | 5 | 22,142 (21,043-23,672) | 623.7 (542.6-717.8) | 828 (783-956) | 63 (58-66) | 107 (105-111) | 0 | 0 | 4,096 in each |
| go-stdlib | 5 | 22,298 (19,701-22,897) | 808.4 (766.7-952.8) | 1100 (882-1280) | 60 (59-69) | 150 (149-152) | 0 | 0 | 4,096 in each |
| go-fasthttp | 5 | 33,657 (31,682-34,835) | 327.0 (313.4-358.2) | 503 (479-542) | 34 (32-36) | 108 (102-113) | 0 | 0 | 4,096 in each |

latency-10k (zrk at a fixed 10,000 requests/s, 1024 connections, 20 s;
each run reached 99.2-99.5 % of the rate; no errors; zrk reports no p99.9
and no count of connections served):

| server | runs | req/s | p99 ms | CPU µs/resp | peak MB | non-2xx |
|---|---:|---:|---:|---:|---:|---:|
| lsrv-epoll | 5 | 9,937 (9,930-9,944) | 16.1 (14.1-28.8) | 80 (77-81) | 34 (33-34) | 0 |
| lsrv-io_uring | 5 | 9,941 (9,934-9,944) | 20.5 (13.3-47.7) | 77 (73-81) | 34 (33-34) | 0 |
| go-stdlib | 5 | 9,945 (9,924-9,951) | 15.2 (13.4-19.3) | 79 (77-81) | 44 (43-45) | 0 |
| go-fasthttp | 5 | 9,947 (9,935-9,954) | 5.4 (4.6-6.3) | 56 (53-58) | 32 (32-33) | 0 |

Read with the caveat above:
- The accept fix on the host: in every sample of every gcannon profile, on
  both backends, all 4,096 connection slots received a response in the
  window, and no recorded response took over 5 s (53rwgc: 50 and 62 in
  baseline, 603 and 591 in pipelined, over five samples). Its pipelined
  p99.9 is still 3.3 to 4.4 s; gcannon allows up to 65,536 requests in
  flight there (4,096 connections, 16 each) on 2 vCPUs, but how many were
  in flight was not measured.
- 53rwgc counted no connections served on the host; the local reproduction
  of its run ([The over-5 s tail](over-5s-tail.md)) found about half of them answered. Its figures are
  therefore not compared with these: baseline throughput is lower than
  53rwgc's (about 23,500 per second against 31,500 to 33,800), p99 higher
  (0.5 to 0.9 s against about 65 ms), and peak memory higher (84 to 86 MB
  against about 40).
- go-stdlib in pipelined answered only 1,463 to 2,118 of the 4,096
  connections in a sample, and 169 of its responses took over 5 s; its
  pipelined figures cover only those connections. Its slow accepts under
  that profile were also seen locally
  ([The over-5 s tail](over-5s-tail.md)); they are go-stdlib's own and
  were not traced further.
- Against the floor (go-stdlib): in baseline and limited-conn the
  throughput ranges overlap go-stdlib's, and so do the p99 ranges except
  lsrv-arena's on io_uring in limited-conn (543 to 718 ms against 767 to
  953); lsrv-arena's peak memory is lower in both (84 to 86 MB
  against 136 to 142 in baseline; 68 to 111 against 149 to 152 in
  limited-conn). In pipelined go-stdlib's figures do not cover all its
  connections, so they are not compared. latency-10k: the ranges overlap
  except peak memory (33 to 34 MB against 43 to 45).
- Against the target (go-fasthttp): ahead in throughput in every throughput
  profile, ranges apart: about 1.7 times in baseline, 1.5 in limited-conn
  and 12 in pipelined, with lower p99 and less CPU per response
  everywhere.
- epoll against io_uring: throughput and CPU per response overlap in every
  profile. io_uring's p99 and p99.9 are lower in baseline (p99 513 to 652
  ms against 785 to 937) and limited-conn (543 to 718 against 837 to 970),
  ranges apart; in pipelined both overlap, and so does p99 in latency-10k
  (zrk reports no p99.9). In limited-conn
  io_uring's peak memory is higher (105 to 111 MB against 68 to 74).

The site's health during the runs: 2,275 probes while the tests, the load
and `bench/dbpairs.sh` ran (18:41-19:24 UTC, `run.sh` tests 18:41, db
18:41-19:05, bench 19:09-19:24), every answer 200, the slowest 0.018 s,
and 75 before and after them, at most 0.003 s; the stop condition never
fired. No Sejm import was scheduled in that window (its timer runs at
05:30 UTC). Disk on the host: 3.7 GB free before the run's 446 MB were
copied, 3.3 GB during, 3.7 GB after its directory was removed.
