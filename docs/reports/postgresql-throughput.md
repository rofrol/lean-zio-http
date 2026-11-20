# lean-db against Go: PostgreSQL measurements

Measured from 2026-11-16 to 2026-11-18 on the M1, in the Linux container and
on vps.frolow.dev; each paragraph names its date, machine and, where one was
recorded, the commit. The choices these runs supported are part of the
contract in [PostgreSQL](../postgresql.md). A historical record, kept as it
was written and not updated as the code changes; the current contracts are
in the documents [README.md](../../README.md#documentation) lists. Item ids
name queue items; `git log --grep ID` finds their commits.

Measured by `bench.sh` (M1, 2026-11-16, 8 loops with 4 connections each
against Go's `net/http` with one pgx pool of 32, both on the same private
cluster, `GET /db?id=42`, 10 s per run):

| server | c=1 req/s | CPU µs/req | c=64 req/s | CPU µs/req |
|---|---:|---:|---:|---:|
| lean-db | 12,512 | 34 | 78,178 | 44 |
| go-db | 11,745 | 68 | 71,610 | 51 |

lean-db reaches 1.06 and 1.09 of Go's throughput (goal: 0.9). Two choices
decided it, measured while building the pool (5 to 10 s runs): readiness
through a one-byte peeking receive instead of zio's `NetPoll`, whose
`poll(2)` probe cost more CPU than the receive and the send together on
macOS (c=64 from 0.86 to 1.07 of Go), and prepared statements (c=1 from
0.78 to 0.90 of Go with the probe; without them, after the probe change,
0.91 at c=1 and 0.98 at c=64). At 64 connections lean-db's p99 latency is
higher than Go's (3.6 against 2.4 ms): HTTP connections spread unevenly over
the loops, and each loop's queries wait for that loop's slots only.

One run's ratio does not show whether a change cost throughput: on the
shared M1 it spreads far wider than the distance to the goal (item fszibv,
2026-11-17, load average 11 to 63 on 10 cores). Fifteen interleaved rounds
of lean-db before item 3jnkx5's deadlines (7c89450), lean-db after them and
go-db, each round's lean-db divided by that round's go-db, gave:

| lean-db | c=1 lowest, median, highest | c=64 lowest, median, highest |
|---|---|---|
| before the deadlines | 0.99, 1.10, 2.14 | 0.47, 1.03, 1.44 |
| with the deadlines | 0.52, 1.08, 4.19 | 0.66, 1.02, 7.83 |

A single `bench.sh` run's 0.74 and 0.83 lie inside both spreads. CPU time
per request, which another process's load disturbs less, did not move in
the five rounds that measured it (rounds at a load average above 30 left
out): lean-db 36 to 39 µs at c=1 before and 37 to 39 after, 41 to 44 µs at
c=64 before and 40 to 44 after; PostgreSQL's backends 12 to 13 µs at c=1
and 18 to 20 µs at c=64 for both, so the `statement_timeout` the deadlines
put in every session's startup options shows no cost there either.

In the Linux container (`linux/Dockerfile` on OrbStack's arm64 VM, 10
vCPUs, kernel 7.2.12-orbstack, epoll), lean-db reaches only about half of
Go at one connection (item 7wvkwz, 2026-11-18, macOS host load average 4
to 26). The runs used the image and archive of [Running](../running.md), with this in
place of `./bench.sh` in the container:

```sh
LIBRARY_PATH=$(pg_config --libdir) lake build lsrv-db &&
  (cd bench/load && go build -o load .) &&
  (cd bench/pgserver && go build -o server .) && bench/dbpairs.sh
```

`bench/dbpairs.sh` runs both servers side by side and alternates which goes
first in each pair, every sample ending after the same 100,000 requests
(`bench/load -n`; the per-request costs include the load's one warm-up
request). Ten pairs:

| c=1, 10 pairs | lowest to highest |
|---|---|
| lean-db / go-db requests per second | 0.49 to 0.56 (median 0.52) |
| p50 latency, lean-db; go-db | 90 to 102 µs; 40 to 41 µs |
| server CPU µs per request, lean-db; go-db | 34 to 37; 23 to 25 |
| voluntary context switches per request, lean-db; go-db | 1.81 to 1.90; 2.30 to 2.40 |
| involuntary ones, lean-db; go-db | 0.13 to 0.23; 1.06 to 1.09 |
| private cluster's CPU µs per request, lean-db; go-db | 19 to 21; 10 to 11 |

lean-db's own database path is not where the time goes; what the reply's
wait holds, PostgreSQL's work or the wake-up, these measurements do not
split. Over 20,000 requests under
`strace -f -c`, lean-db makes 9 system calls per request (4 `recvfrom`, one
of them the peek's re-armed receive failing with `EAGAIN`; 2 `sendto`;
3 `epoll_pwait2`; 5 `epoll_ctl` in all, so no registration per request) and
go-db 16 (3 `futex`, 1 `nanosleep`, 4 `epoll_pwait`, 5 `read`, 3 `write`);
PostgreSQL's backend makes the same 2 `recvfrom`, 1 `sendto` and 1
`epoll_pwait` per request for both. The sequence (`strace -f -tt`) shows the
loop sending the query and then waiting in `epoll_pwait2` with no other turn,
and libpq reading the reply with one `recvfrom`. A temporary timing patch of
`zig/src/pg.zig` (not kept) split lean-db's request at its median: 42 to
51 µs from the previous answer's delivery to the next query's send (the
client's turn, the loop's wake-up on the HTTP request, parsing and the
handler), 5 µs to send and flush the query, 34 to 36 µs waiting for the
reply (PostgreSQL and the loop's wake-up), 3 µs in libpq and `pg.c`, 7 µs
delivering the answer and sending the response. lean-db's own database path
is about 15 µs; the rest is two waits per request (the first also holds the
client's work, the second PostgreSQL's), each ending in a wake-up of the
loop's parked thread.

What the measurements fit, without proving it: in the VM, waking a thread
whose vCPU went idle costs tens of microseconds, and Go's runtime keeps
vCPUs from going idle by spinning its idle threads before they park (the
`futex`, `nanosleep` and involuntary switches above; go-db does not switch
less than lean-db, it switches onto vCPUs that are still running). Two
differential runs point that way, though each changes more than that one
thing. With go-db at `GOMAXPROCS=1` (`bench/dbpairs.sh -g 1`; one
processor, so no idle one to spin on), six pairs gave go-db 8,454 to 14,883
requests per second at a p50 of 48 to 96 µs, lean-db/go-db 0.67 to 1.33
(median 0.86), and go-db's private cluster's CPU rose to 13 to 24 µs per
request, around lean-db's 19 to 21, although PostgreSQL makes the same
system calls per request for both servers. With ten `nice 19` busy loops
started in the container beside `bench/dbpairs.sh` to keep every vCPU awake
(four pairs of 50,000), lean-db's p50 fell to 41.5 to 41.9 µs, go-db's
usual p50, while both lost their throughput to the busy loops (p99 4 ms;
go-db's p50 2 ms), so only lean-db's p50 of that run is evidence. On macOS
the same commit gave 1.12 at c=1, and go-db there spent 83 µs of CPU per
request against 29 in the container. The 0.64 of rqc3ql's single
`bench.sh` run lies near this gap; the remaining gap at `GOMAXPROCS=1`
(median 0.86, pairs from 0.67 to 1.33) was not traced further. Whether
lean-db should spin before parking, which would trade idle CPU for
latency, is a separate decision that needs a measurement on the deployed
host's kernel first.

That measurement (item akj76n, run by item dtlin3 in the same window as
[HttpArena on the VPS](httparena-vps.md): vps.frolow.dev, 2026-11-18, `bench/arena/run.sh db`,
the same scope and namespaces, as `nobody`, at 2ae7e98 with dtlin3's bench/
changes only) shows no such gap on the deployed host. `bench/dbpairs.sh`
(ten pairs of 100,000 requests at c=1): lean-db/go-db 1.08 to 1.32 (median
1.21); lean-db 3,247 to 3,661 requests per second, p50 254 to 282 µs, p99
511 to 654 µs, 121 to 134 µs of CPU per request, 1.76 to 1.86 voluntary and
0.34 to 0.51 involuntary switches per request; go-db 2,681 to 3,028, p50 311
to 344 µs, p99 615 to 776 µs, 216 to 245 µs of CPU, 8.53 to 8.80 and 1.79
to 1.88 switches; the private cluster's CPU 68 to 76 µs per request for
lean-db, 74 to 83 for go-db. With `-g 1`: 1.00 to 1.22 (median 1.09); lean-db
2,904 to 3,624 requests per second (p50 256 to 319 µs, 122 to 148 µs of
CPU), go-db 2,838 to 3,254 (p50 288 to 327 µs, 169 to 195 µs of CPU, 5.28
to 5.54 and 0.90 to 1.06 switches). A request on the VPS takes several times as
long as in the container, so these figures do not compare with the M1's. On
the deployed host lean-db is faster with Go's default GOMAXPROCS (ranges
apart) and spends less CPU per request in both runs; with `-g 1` their
throughput and p50 ranges overlap. Neither run shows a c=1 gap there for a
spin before parking to close.

Collecting rows in chunks (item 4lmjda) against single-row mode, measured
by `bench/rows.sh` (M1, 2026-11-17, load average 11 to 17 from other work,
two rounds of 8 s, a fresh `lsrv-db` per case, 8 loops with 4 connections
each, `GET /rows?n=N&len=L`: N rows of L bytes; server CPU µs per request,
then requests per second, one value per round):

| N, L, connections | single row | chunks of 16 | chunks of 64 | chunks of 256 |
|---|---|---|---|---|
| 1, 100, c=1 | 37, 37; 11,641, 11,670 | 41, 38; 9,815, 11,231 | 47, 37; 7,616, 11,444 | 37, 37; 12,518, 11,647 |
| 100, 100, c=1 | 97, 93; 6,409, 6,647 | 84, 82; 7,079, 7,042 | 82, 82; 6,890, 6,967 | 82, 82; 6,859, 6,791 |
| 1000, 100, c=1 | 621, 594; 1,238, 1,326 | 521, 497; 1,431, 1,524 | 504, 490; 1,450, 1,538 | 512, 510; 1,228, 1,238 |
| 1000, 100, c=64 | 732, 754; 6,989, 6,990 | 589, 601; 7,846, 7,791 | 585, 589; 7,564, 7,705 | 634, 628; 7,722, 7,295 |
| 900, 1000, c=64 | 4,236, 4,299; 1,235, 1,117 | 4,191, 4,242; 1,240, 991 | 4,259, 4,421; 1,212, 1,057 | 4,360, 4,334; 1,229, 1,080 |

Peak resident set size of the process, MB per round: at 1000 rows of 100
bytes and c=64, 28.6 and 28.1 single-row, 27.6 and 27.9 in chunks of 16,
26.2 and 26.2 of 64, 28.6 and 30.1 of 256; at 900 rows of 1000 bytes,
77.0 and 77.7, 77.9 and 77.3, 77.5 and 46.4, 99.6 and 140.5. The first
round's one-row runs in chunks of 16 and 64 were slower at a load average
of 14 to 17; three more rounds at one row against single-row mode, at a
load average of 10 to 14, gave 37 µs and 11,477 to 11,643 requests per
second for both single-row and chunks of 16 at c=1, and 41 to 46 µs,
73,614 to 76,359 for both at c=64 (chunks of 64: the same), so one row
costs the same. Chunks of 16 cost 12 to 20% less CPU per request at 100
and 1000 rows of 100 bytes and serve 11 to 16% more requests at 1000 rows;
chunks of 64 do the same within noise (1 to 3% less CPU, which a round's
spread covers) with four times the residual in libpq ([PostgreSQL](../postgresql.md), "Bounded only in part"), so 16 was chosen. Chunks of 256 gain no more CPU, serve no more
requests at 1000 rows and c=1 (not traced, since they were not chosen) and
raised the peak memory with large rows, as their larger residual predicts.
At 1000-byte rows the cost is in the data, not the per-row results, so no
mode differs within noise.

## 2026-11-19: the peeking receive against NetPoll (item jexowc)

A rerun of the first paragraph's comparison of readiness through a one-byte
peeking receive and through zio's `NetPoll`, which it does not replace: that
one was single runs; this one is interleaved rounds. Commit bccf77f, zio
f8ca47367765, Zig 0.17.1, PostgreSQL 18.6, on the shared M1 (macOS 27.2,
one-minute load average 8 to 22 after the runs). `lsrv-db` built twice, once
as it is ("peek") and once with `Slot.rpoll` as
`ev.NetPoll.init(self.fd, .recv)` ("NetPoll"; nothing else changed). Both
processes ran for the whole session against one private cluster (Unix
socket), 8 loops with 4 connections each; only one of them received load at
a time. `GET /db?id=42`, 10 s per server and concurrency; in each round c=1
ran before c=64, and the server named first ran first. Requests per second
and server CPU time per request (µs, from `ps` before and after the run):

| round, first | c=1 peek | c=1 NetPoll | c=64 peek | c=64 NetPoll |
|---|---|---|---|---|
| 1, peek | 11,966; 35.8 | 10,519; 36.5 | 78,901; 40.8 | 65,000; 50.2 |
| 2, NetPoll | 13,625; 33.9 | 10,122; 38.2 | 33,865; 39.5 | 54,994; 52.6 |
| 3, peek | 12,196; 36.1 | 10,801; 37.2 | 77,599; 43.2 | 65,627; 51.0 |
| 4, NetPoll | 11,816; 37.1 | 9,772; 40.1 | 62,442; 37.6 | 48,233; 41.3 |
| 5, peek | 3,185; 67.8 | 5,161; 54.5 | 48,077; 35.8 | 39,034; 49.8 |
| 6, NetPoll | 12,527; 37.4 | 10,285; 41.0 | 73,508; 41.2 | 46,250; 46.8 |
| 7, peek | 12,220; 35.3 | 10,256; 36.5 | 80,552; 40.5 | 65,759; 53.4 |
| 8, NetPoll | 12,362; 35.3 | 10,593; 36.4 | 79,001; 41.9 | 65,517; 50.5 |

Within each round the peek cost less CPU per request in 8 of 8 rounds at
c=64 and 7 of 8 at c=1 (not in round 5, where both servers lost most of
their c=1 throughput at a load average of 19), and served more requests per
second in 7 of 8 at each concurrency. Medians of the unrounded values: at
c=64 40.6 against 50.3 µs and 75,554 against 59,997 requests per second; at
c=1 35.9 against 37.7 µs and 12,208 against 10,270. One shared, loaded
machine and one query; the syscall measurements and the limits of this
result are in
[What the dependency assumptions rest on](dependency-assumptions.md), point 4.

## 2026-11-20: the peeking receive against NetPoll in the Linux container (item g62mok)

The previous section's comparison, rerun on Linux; it replaces nothing (the
M1 result stands for macOS). Preliminary: the container is OrbStack's VM
(kernel 7.2.12, aarch64, 10 CPUs) on the same shared M1, whose one-minute
load average was 18 to 21 before and after the run; the VM's own was 4.7 to
11.0 during it. Commit 4b2e1a4, zio f8ca47367765, `linux/Dockerfile`'s
image (Zig 0.17.1, Lean nightly-2026-11-19, PostgreSQL 17 from Debian's
archive), the container's seccomp filter off for both backends (io_uring
needs it). `lsrv-db` built four times in the container, "peek" as it is and
"NetPoll" with `Slot.rpoll` declared as `ev.NetPoll` and armed with
`ev.NetPoll.init(self.fd, .recv)` (nothing else changed), each on epoll and
on io_uring (`LSRV_LINUX_BACKEND`). Per backend both processes ran for the
whole session against one private cluster (`bench/lib.sh`, Unix socket),
8 loops with 4 connections each; only one received load at a time. `GET
/db?id=42` with bench/load, each sample ending after the same number of
completed requests as in `bench/dbpairs.sh` (30,000 at c=1, 200,000 at
c=64), after one unprinted warm-up of each server; ten rounds, c=1 before
c=64, the server named first ran first. Requests per second and server CPU
time per request (µs, from `/proc` before and after; the clock tick, 10 ms,
is about 0.3 µs per request at c=1 and 0.05 at c=64). The script was not
kept in the repository.

epoll:

| round, first | c=1 peek | c=1 NetPoll | c=64 peek | c=64 NetPoll |
|---|---|---|---|---|
| 1, peek | 8,884; 39.3 | 8,555; 40.7 | 84,143; 22.4 | 83,072; 23.5 |
| 2, NetPoll | 9,376; 38.3 | 9,632; 36.7 | 80,076; 23.6 | 82,828; 22.9 |
| 3, peek | 9,632; 36.7 | 9,725; 36.3 | 83,210; 23.2 | 80,391; 23.4 |
| 4, NetPoll | 9,675; 36.7 | 9,522; 36.3 | 83,567; 22.8 | 66,066; 25.5 |
| 5, peek | 9,544; 37.0 | 7,509; 46.7 | 79,684; 23.4 | 77,624; 23.8 |
| 6, NetPoll | 8,555; 41.7 | 8,138; 42.3 | 81,244; 23.3 | 82,283; 23.1 |
| 7, peek | 9,106; 38.3 | 10,370; 35.0 | 84,963; 22.5 | 84,904; 22.3 |
| 8, NetPoll | 10,160; 35.0 | 9,994; 36.0 | 84,277; 22.6 | 91,256; 22.0 |
| 9, peek | 10,228; 35.3 | 8,891; 39.7 | 80,297; 23.6 | 87,110; 22.9 |
| 10, NetPoll | 9,410; 37.3 | 9,740; 36.0 | 60,588; 28.6 | 69,279; 26.3 |

io_uring:

| round, first | c=1 peek | c=1 NetPoll | c=64 peek | c=64 NetPoll |
|---|---|---|---|---|
| 1, peek | 7,917; 44.3 | 8,789; 41.0 | 83,368; 23.6 | 87,952; 22.4 |
| 2, NetPoll | 9,807; 36.7 | 9,142; 39.0 | 91,069; 21.9 | 87,309; 22.1 |
| 3, peek | 10,193; 35.3 | 10,081; 36.0 | 86,995; 23.0 | 90,260; 22.5 |
| 4, NetPoll | 9,877; 36.3 | 9,979; 36.7 | 86,515; 22.6 | 84,848; 22.6 |
| 5, peek | 10,014; 36.0 | 7,443; 50.3 | 89,224; 22.7 | 84,348; 22.5 |
| 6, NetPoll | 9,868; 36.3 | 9,643; 37.0 | 88,242; 23.0 | 87,178; 23.3 |
| 7, peek | 10,263; 35.7 | 9,750; 37.0 | 86,680; 22.9 | 95,744; 21.7 |
| 8, NetPoll | 9,810; 36.7 | 9,707; 37.0 | 93,814; 21.8 | 88,588; 22.6 |
| 9, peek | 9,670; 37.3 | 9,762; 37.7 | 90,018; 22.4 | 71,277; 24.8 |
| 10, NetPoll | 9,038; 39.7 | 8,921; 39.7 | 64,427; 28.0 | 82,069; 23.6 |

Medians of CPU time per request, peek against NetPoll: on epoll 37.15
against 36.5 µs at c=1 and 23.25 against 23.25 at c=64; on io_uring 36.5
against 37.35 at c=1 and 22.8 against 22.55 at c=64. The peek cost less CPU
per request in 5 of 10 rounds on epoll at c=1, 4 of 10 at c=64 (NetPoll in
the other 6), and on io_uring in 8 of 10 at c=1 (one tie) and 4 of 10 at
c=64 (one tie); there the peek's wins were by 0.3 to 2.3 µs (14.3 in round 5) and
NetPoll's one, round 1, by 3.3, against a clock tick of about 0.3 µs. Requests
per second, medians, peek against NetPoll: epoll 9,477 against 9,577 (c=1)
and 82,227 against 82,556 (c=64); io_uring 9,839 against 9,675 and 87,619
against 87,244. Some samples fell well below their build's median
throughput at that backend and concurrency: at c=64 epoll round 4's NetPoll
(20% below), round 10's peek on both backends (26%) and io_uring round 9's
NetPoll (18%); at c=1 round 5's NetPoll on both backends (22 and 23%). They
hit either build; leaving out round 10 moves no c=64 CPU median by more
than 0.2 µs (epoll 23.2 against 23.1, io_uring 22.7 against 22.5).

So in this preliminary run the CPU medians of the two probes differed by
less than 1 µs per request (2.3% at most, against the smaller median) in
both directions on both backends, and neither build won a clear majority of
rounds except the peek at c=1 on io_uring (8 of 10, one tie; its median
0.85 µs lower, about three clock ticks per request). The M1's quarter more
CPU for NetPoll at c=64 (previous section) was not observed, which agrees
with the container's `poll(2)` costing about what the receive costs
([What the dependency assumptions rest on](dependency-assumptions.md),
point 4). Ten rounds under this load rule out a difference of that size,
not a small one hidden by the VM's scheduling noise. Not measured: bare metal, x86-64, the VPS, a TCP connection to
the database, how often a wait parks.
