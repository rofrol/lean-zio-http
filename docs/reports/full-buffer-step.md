# One step on a full buffer of pipelined requests

Measured on 2026-11-19 by item vhvejg, at commit 5dfb004 (with this item's
harness), and, for comparison, at 0164ce4, the commit before 9c774f0
(item paarzq, which answers a connection's pipelined requests in one send),
on the M1 (macOS, kqueue, 10 CPUs) under a load average of 7 to 10 from
other programs. A historical record, kept as it was written and not updated
as the code changes; the current contracts are in the documents
[README.md](../../README.md#documentation) lists. Item ids name queue items;
`git log --grep ID` finds their commits.

## The question

Since 9c774f0, `Conn.gather` answers every pipelined request in the buffer
that fits in one send (`maxResponseBytes`, 65,536 bytes) within the one
`Conn.step` on the receive, consuming each with
`buf.extract consumed buf.size`, which copies the rest of the buffer once per
request. Before, a connection answered one request per loop turn. Two
questions came from consult round 20261119-120420-c1d1: what the worst step
costs, the quadratic copying included, and how long a second connection
ready on the same loop waits meanwhile. Measurement only; a change to the
adapter or the connection comes back for approval.

## How it was measured

- In process: `lsrv-parsebench`'s `full` section
  ([running](../running.md)) on `Corpus.fullCases`: a receive of `inCap`
  (16,388) bytes, as near as whole requests fill it, of one request
  pipelined. `full-404` is the smallest request the H1 adapter completes,
  `GET / HTTP/1.1\r\nHost:\r\n\r\n` (25 bytes, answered 404 in 128 bytes);
  `full-pipeline` is gcannon's 48-byte `GET /pipeline` (answered in 103
  bytes). It times the one `Conn.step` on the receive (`first step`), every
  step until the connection asks to receive again (`receive`), and only the
  suffix copies the first step makes (`copy`, one `extract` per request it
  answers). Median of five runs of 2,000 receives.
- On the loop: `bench/fairness/run.sh` starts `lsrv-arena 1` (one loop) and
  runs `bench/fairness`: a loader connection writes one case's request back
  to back without pause, meant to fill its buffer on every receive, while a probe
  connection on the same loop sends `GET /pipeline` and waits for its answer,
  20,000 times one after the other. The probe alone first. Two runs at each
  commit; `ARENA` pointed the script at 0164ce4's build.

### In process (5dfb004)

| case | requests per receive | responses in the first send | first step | receive | copy | bytes copied |
| --- | --- | --- | --- | --- | --- | --- |
| full-404 | 655 | 512 | 1,570 µs | 2,009 µs | 107 µs | 5,100,800 |
| full-pipeline | 341 | 341 | 1,291 µs | 1,292 µs | 55 µs | 2,782,560 |

`full-404`'s first step stops at 512 responses, the send's limit (512 × 128
= 65,536); the other 143 requests are answered after that send completes.
These are the largest steps measured, not a bound for every application:
the requests one step answers are bounded by `maxResponseBytes` over the
smallest response, but what each costs depends on the application. Per
response the first step costs about 3.1 µs (`full-404`, 1,570 / 512) and
3.8 µs (`full-pipeline`, 1,291 / 341), against 3.6 µs per request of the
16-request `pipelined` shape's `step` in the same run. The suffix copies
measured alone take 6.8 % of the first step for `full-404` and 4.2 % for
`full-pipeline`; the rest is mostly the parse and the response of each
request, which item owgate profiled
([Where H1's parse spends lsrv-arena's CPU](h1-parse-profile.md)). Inside
the step the copies may cost somewhat more or less than alone (cache and
allocator state differ), so these shares are estimates.

The table is one run. Two other runs on the same machine (one before the
harness's final checks, which time nothing more, and one after, at a load
average near 14) gave first steps of 1,649 and 1,583 µs and copies of 107
and 154 µs for `full-404`, and first steps of 1,329 and 1,526 µs and copies
of 56 and 54 µs for `full-pipeline`; in the last run `full-pipeline`'s first
step measured longer than its whole receive, which includes it: the first
steps differ by up to 18 % and `full-404`'s copies by 44 % between runs
taken minutes apart on this loaded machine. The copies stayed under 10 % of the first step in
every run.

## On the loop

The probe's round trip, two runs each (µs; the loader's responses per
second while the probes ran):

| commit | loader | p50 | p90 | p99 | p99.9 | loader responses/s |
| --- | --- | --- | --- | --- | --- | --- |
| 5dfb004 | none | 44, 44 | 57, 56 | 97, 94 | 220, 149 | - |
| 5dfb004 | pipeline | 727, 744 | 777, 794 | 880, 914 | 1,589, 2,143 | 230,766, 226,088 |
| 5dfb004 | 404 | 1,105, 1,093 | 1,207, 1,188 | 1,589, 1,340 | 5,587, 2,847 | 275,525, 282,534 |
| 0164ce4 | none | 43, 50 | 54, 80 | 89, 135 | 138, 256 | - |
| 0164ce4 | pipeline | 40, 51 | 64, 81 | 88, 119 | 114, 175 | 31,127, 27,400 |
| 0164ce4 | 404 | 39, 47 | 65, 78 | 92, 147 | 133, 618 | 32,171, 27,450 |

Since 9c774f0 the probe's median round trip beside one such loader is 0.73
to 1.1 ms (about 0.55 to 0.7 of the first step measured in process), against
39 to 51 µs before, and its 99th percentile 0.9 to 1.6 ms, against 88 to
147 µs before, while the
loader gets 7 to 10 times the responses per second. The harness does not
observe the server's steps: that the loader's receives fill the buffer, and
that the probe waits behind its steps, are inferred from the continuous
stream and from the round trips' matching the step's length, not seen. The
maxima, single samples among 20,000, ranged from 0.2 to 76 ms in every
configuration, the probe alone and 0164ce4 included; they were not traced,
and nothing above rests on them.

## What it means

- The quadratic copying is not what holds the loop: the copies the worst
  measured step makes take about 0.1 ms of its 1.6 ms, so an adapter that
  takes an offset into the buffer instead would shorten the step by about
  that much.
- The step's length is the work of up to `maxResponseBytes` / (smallest
  response) requests, here 512, done in one turn. A connection ready on the
  same loop waits for it; with several such pipelining connections on one
  loop the waits would add up (not measured).
- Whether to bound that work per step, at the cost of the pipelined
  throughput the batch brought, is a choice for the owner; it was proposed
  as a follow-up item.
