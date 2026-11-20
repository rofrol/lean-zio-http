# The over-5 s tail: connections accepted late

Measured on 2026-11-17 in OrbStack's arm64 Linux VM on the M1: the
diagnostic by item 6p6tu6 (recorded in 37246fe, before the fix) and the run
after the fix by item sakmfp (caeba5f). A historical record, kept as it was
written and not updated as the code changes; the current contracts are in
the documents [README.md](../../README.md#documentation) lists. Item ids
name queue items; `git log --grep ID` finds their commits.

A diagnostic, reproduced locally before any use of the VPS:
`bench/arena/local.sh OUT ARENA [ROUNDS]` runs HttpArena's baseline
(adapted: its GET and Content-Length POST templates for every server, without
the chunked POST, which lsrv-arena answers 501; label added 2026-11-20, item
5f54l4) and pipelined
profiles (gcannon, 4,096 connections, 5 s, at the commits
`build.sh` pins) against lsrv-arena on epoll, go-stdlib and go-fasthttp in
OrbStack's arm64 Linux VM on the M1 (kernel 7.2.12), each server and the
generator pinned to the same two CPUs, with `bench/arena/trace.bt`
(bpftrace) beside every sample: each connection's accept delay, from the
handshake's completion in the kernel to `accept(2)` returning it, and the
server's system calls; `PERF=1` adds a CPU profile (`perf record -g`). It is
a stress diagnostic on another machine and architecture, not a measurement
of the VPS. Two rounds, 2026-11-17 (`summary.txt`'s figures):

| server | profile | responses in 5 s | over 5 s | p50 / p99.9 | accepted during the load | slowest accept |
|---|---|---:|---:|---|---:|---:|
| lsrv-arena | baseline | 525,852; 559,356 | 10; 16 | 15 ms / 2.6 s | 2,257; 2,250 of 4,096 | 5.1 s |
| go-stdlib | baseline | 647,755; 663,316 | 0; 0 | 35 ms / 0.16-0.17 s | 4,096 | 0.16-0.17 s |
| go-fasthttp | baseline | 987,747; 1,036,942 | 0; 0 | 24 ms / 0.09-0.10 s | 4,096 | 0.01-0.08 s |
| lsrv-arena | pipelined | 795,825; 865,537 | 181; 142 | 150 ms / 4.7 s | 1,944; 2,111 of 4,096 | 5.1 s |
| go-stdlib | pipelined | 1,004,384; 978,977 | 0; 0 | 0.2 ms / 3.4-4.9 s | 4,096 | 1.5-3.0 s |
| go-fasthttp | pipelined | 8,694,368; 8,837,232 | 0; 0 | 43 ms / 0.13-0.14 s | 4,096 | 0.05-0.10 s |

The table's samples were taken before `trace.bt` was scoped to the
sample's network namespace and acknowledged its attachment itself; four
lsrv-arena samples after that change gave the same shape (accepted during
the load 2,311 and 2,343 of 4,096 in baseline, 1,978 and 1,998 in
pipelined; 14-20 and 208-218 over 5 s), and go-fasthttp's two 4,096.

The tail reproduces at the scale of item 53rwgc's VPS run (7-14 per
baseline sample, about 120 per pipelined one) and is not a lost wakeup or a
fairness bug among served connections: it is the accept path.
- **One accept per loop turn.** `acceptCb` (`zig/src/serve.zig`) handles the
  one connection its accept returned and adds the next accept. zio tries
  that accept at once, but queues its completion, and the callback runs only
  on the loop's next turn: `processCompletions` runs only what was queued
  when it began (zio 53ed3c377317, src/ev/loop.zig, "Drain only what was
  queued at entry ... The rest runs next tick"). So each loop takes one
  connection per turn, and a turn under this load runs the completions of
  hundreds of connections (2,478 `epoll_pwait2` and 2,481 `accept4` in a
  baseline sample, 1,942 and 1,946 in a pipelined one, for 0.5 and 0.8
  million responses). The Go servers accept in a loop of their own.
- **What gcannon shows of it.** gcannon starts its clock once every
  connection's handshake is done, which the kernel completes without the
  server, and sends each connection's first requests at once; it counts only
  answered requests, from their send. So about half the connections were
  never accepted during the load, invisible in its counts; those accepted
  near its end were answered after more than 5 s (in pipelined, 16 requests
  each: 142-181 over 5 s, 14-15 connections accepted after 5 s). Item
  53rwgc's VPS figures had the same shape; item dtlin3's rerun after the
  fix counted the connections served there
  ([HttpArena on the VPS](httparena-vps.md)): all 4,096, with no
  response over 5 s.
- **The check of the cause** (a diagnostic build, not committed): with
  `acceptCb` taking up to 64 more pending connections with `accept(2)`
  before it adds the next accept, every connection was accepted during the
  load, the slowest after 0.25-0.39 s, no response took over 5 s in two
  baseline and two pipelined samples, and p99.9 fell to 0.19-0.22 s
  (baseline) and 0.69 s (pipelined); the median rose (about 35 ms baseline,
  390-410 ms pipelined), as twice the connections then share the same two
  CPUs. Item sakmfp made that change (`LoopCtx.acceptMore`; [Production contract](../production-contract.md), "Admission"); its own run is below.
- io_uring was not traced locally; its completions take the same deferred
  path in zio's loop, and 53rwgc's VPS counts for it were the same.
- go-stdlib's pipelined samples also accepted slowly (up to 3 s) and
  showed a tail (0 here, 0 to 2,986 over 5 s in six other local samples,
  65 over five on the VPS); that is go-stdlib's own, not traced
  further.

What a pipelined response costs (lsrv-arena, the same runs): 1.02 `sendto`
per response (go-stdlib: 1.02 `write`; go-fasthttp: 0.063, one per 16) and
0.066 `recvfrom` (one per 16 requests). The transport tries each send
itself and reports it on the loop's next turn (`LoopCtx.readyCb`); only
then does `Conn.step` take the next pipelined request from the buffer, so a
connection's 16 pipelined responses take 16 sends and 16 turns. The CPU
profile (inclusive shares of the server's samples, pipelined; baseline in
parentheses): H1's parse (`H1Adapter.Parser.parse`) 41 % (39 %), the send
34 % (25 %), of it 27 % (20 %) in the kernel's `sendto` with loopback
delivery, the response's rendering and checks 8 % (8 % with the
application's sum), the deadline timers (`newArm`, `clearTimer`) 4 %
(4 %), the `recvfrom` calls 0.7 % (3.6 %), `epoll_pwait2` under 0.5 %. By
function, Lean's allocator and reference counting take about 20 % of all
samples. Each request starts a fresh H1 machine, which copies the rest of
the buffer (`buf.extract p.fed buf.size`) but parses only that request's
head: the parse costs about 3.8 µs per pipelined request against 5.9 µs per
baseline one (its share times the CPU per response below), though each
pipelined one is parsed from a buffer of up to 16, so it is not a re-parse
of the buffer. So pipelining saves only the receives; what remains per response is a parse
by H1 and a send of its own, where go-fasthttp writes 16 responses with one
send. Server CPU per response here: 9.2 µs pipelined, 15.2 µs baseline
(go-stdlib 7.4 and 11.3, go-fasthttp 0.8 and 6.2), whole-run CPU over the 5 s
window's responses.

After the fix (item sakmfp, 2026-11-17): the same script, two rounds, with
lsrv-arena built from the committed `acceptMore` (each accept callback
takes up to 64 connections). Every lsrv-arena sample accepted all 4,096
connections during the load, none after 1 s, and no response took over
5 s (gcannon printed no overflow line); each of its responses was 2xx,
and each of its servers printed `stopped` at its SIGTERM.

| server | profile | responses in 5 s | over 5 s | p50 / p99.9 | accepted during the load | slowest accept |
|---|---|---:|---:|---|---:|---:|
| lsrv-arena | baseline | 556,431; 521,054 | 0; 0 | 35-37 ms / 0.24-0.25 s | 4,096; 4,096 | 0.31-0.32 s |
| go-stdlib | baseline | 632,402; 616,999 | 0; 0 | 37-38 ms / 0.17-0.31 s | 4,096 | 0.13-0.34 s |
| go-fasthttp | baseline | 932,112; 1,023,968 | 0; 0 | 22-25 ms / 0.10-0.12 s | 4,096 | 0.06-0.09 s |
| lsrv-arena | pipelined | 747,171; 766,901 | 0; 0 | 421-432 ms / 0.74-0.76 s | 4,096; 4,096 | 0.42-0.45 s |
| go-stdlib | pipelined | 900,174; 1,045,860 | 1,155; 0 | 0.15 ms / 2.6-5.0 s | 4,096 | 2.6-4.9 s |
| go-fasthttp | pipelined | 9,085,952; 7,779,648 | 0; 0 | 42-46 ms / 0.16 s | 4,096 | 0.07-0.18 s |

lsrv-arena's responses now cover every connection, so they are not
comparable with the first table of this section, taken before the fix,
when about half the connections were accepted during the load; the median
rose as in the diagnostic build, since twice the connections share the two
CPUs. Item dtlin3 re-measured the VPS after the fix
([HttpArena on the VPS](httparena-vps.md)).

## The tracers' exit statuses (item cmb7vk, 2026-11-20)

`local-inner.sh` used to discard bpftrace's and perf record's exit statuses
after the SIGINT that ends them. Measured on 2026-11-20 in local.sh's
privileged container (`local.Dockerfile`: bpftrace 0.23.2, perf 6.12.117,
dash 0.5.12) in OrbStack's arm64 VM on the M1 (kernel 7.2.12), each tool
started from dash in the background and signalled by it:

| tool and case | exit status |
|---|---:|
| bpftrace, SIGINT once its probes are attached (after BEGIN ran; `trace.bt` with a BEGIN added, and a `-e` script) | 0, maps printed |
| bpftrace, SIGINT while it attaches (after "Attaching N probes...", before BEGIN; 4 of 4 runs) | 255, nothing else printed |
| bpftrace, a script error | 1 |
| bpftrace, SIGKILL | 137 |
| perf record -q -F 999 -g -p PID, SIGINT while recording | 130, data written (977 and 985 samples) |
| perf record, its target exits first | 0 |
| perf record, no such PID | 244 |
| perf record, output path unwritable | 255 |

`local-inner.sh` now requires 0 from bpftrace and 130 from perf record after
its SIGINT, and stops the run with the status otherwise; bpftrace runs under
start-polled.sh's supervisor (`start_supervised`), whose record of its exit
ends the wait for its attach with that status. `PERF=1 bench/arena/local.sh`
then ran one round end to end at commit 648ef2e plus this change, with every
check passing and a profile of each lsrv-arena sample. Its figures are not
recorded: the change touches only the tracers' handling.
