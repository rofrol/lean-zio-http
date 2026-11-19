# Where bench/fairness's slowest probe round trips come from

Measured on 2026-11-19 by item srx6tz, at commit 5d7f284, on the M1 Pro
(macOS, kqueue, 8 performance and 2 efficiency cores), with the server
built from that commit plus the investigation's trace
([trace.patch](fairness-probe-maxima/trace.patch)). A historical record,
kept as it was written and not updated as the code changes; the current
contracts are in the documents [README.md](../../README.md#documentation)
lists. Item ids name queue items; `git log --grep ID` finds their commits.

## The question

Item vhvejg ([One step on a full buffer of pipelined
requests](full-buffer-step.md)) saw `bench/fairness`'s probe reach 0.2 to
76 ms in single samples in every configuration, also with no loader and
on the 0164ce4 build, while its medians were 40 µs to 1.1 ms. This item
traces those samples to tell three causes apart: the probe not running,
the server's loop thread not running, and the server's own work (the Lean
runtime, the allocator, kqueue).

## How it was measured

- The host could not be made idle: other sessions, builds and a browser
  ran on it throughout (load average 7 to 14, `top` reporting 17 % to 66 %
  idle CPU per second), and stopping them was not this item's to do. In
  place of an idle host, each run measures the host's contention beside
  it (the canary and `top` below) and correlates it with the slow samples.
- The probe (`bench/fairness`, its new `-trace` and `-spin` flags): the
  wall-clock time before each request's write and when the write returned,
  and the end of its read of the response. With `-spin` it polls the
  socket without blocking on a locked thread, so its largest pause between
  two polls shows the probe not running, by the OS's scheduling or Go's.
- The server: `lsrv-arena 1` built with
  [trace.patch](fairness-probe-maxima/trace.patch), which records each
  callback of the loop (`recvCb`, `sendCb`, `readyCb`, `timerCb`,
  `pollCb`) and each `kevent` call of zio's kqueue backend. For each it
  records the wall clock, the loop thread's CPU clock
  (`CLOCK_THREAD_CPUTIME_ID`) and the process's voluntary and involuntary
  context switches (`getrusage`) at its start and end, and it writes them
  when the loop ends. Wall time less the thread's CPU time over a span is
  the time the loop thread did not run in it, for any reason. The switch
  counts are the process's. Its other threads were blocked meanwhile (the
  main thread in a `read` of its shutdown pipe), so the counts are
  attributed to the loop thread. The patch applies to 5d7f284 and to
  zio f8ca473 as the first `lake build` fetches it into `zig/zig-pkg/`. It
  supports macOS (kqueue) and one loop only. Its buffer holds 4 Mi events;
  the largest run recorded 225,361, so none was dropped.
- Beside each run, a canary ([canary.go](fairness-probe-maxima/canary.go))
  spins on one thread of its own process and records every pause over
  200 µs, and `top` samples the host's CPU by process each second.
- [runs.sh](fairness-probe-maxima/runs.sh) runs the three loads (none,
  `pipeline`, `404`). Runs a and b below are its blocking runs. Round r2
  ran the same steps with and without `-spin`, but without the canary and
  `top`. Round r3 ran them with the probe at `GOGC=off` and at
  `GOMAXPROCS=2`, its canary run through `go run` for 40 s. A first
  round, r1, had no context-switch counts in its trace and is not quoted.
  The raw traces were not kept in the repository.
- [analyze.py](fairness-probe-maxima/analyze.py) matches each sample slower
  than 3 ms to the probe connection's receive callback that sends its
  response. It splits the time from the write's return to that
  callback's end into the loop thread's CPU time and the time the thread
  did not run. The rest of the sample is the write and the time from the
  callback's end to the end of the probe's read. That last part covers
  the kernel's delivery, the wakeup of the probe's goroutine and its read.
  Samples it cannot place are counted and left out.
  [overlap.py](fairness-probe-maxima/overlap.py) counts the slow samples
  that overlap a canary pause over 1 ms, against the count expected by
  chance. Without root, no kernel trace (dtrace, ktrace, packet capture)
  was available, so which threads ran in the loop thread's place is not
  observed; `top`'s one-second samples name what used the host.
- The first, untraced run of `bench/fairness/run.sh` at 5d7f284
  reproduced the maxima: 0.54 ms (no loader), 93 ms (`pipeline`) and
  26 ms (`404`). The 0164ce4 build was not measured again.

## Results

Runs a and b (20,000 probes each; times in µs; "> 3 ms" counts the
samples; the split is of those samples' summed time):

| run | load | p50 | p99.9 | max | > 3 ms | loop thread CPU | loop thread not running | after the server's callback | largest callback CPU |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| a | none | 50 | 106 | 637 | 0 | - | - | - | 235 |
| a | pipeline | 759 | 2,060 | 14,196 | 10 | 15 % | 58 % | 27 % | 1,867 |
| a | 404 | 1,125 | 4,024 | 36,677 | 30 | 18 % | 54 % | 27 % | 1,985 |
| b | none | 44 | 130 | 542 | 0 | - | - | - | 91 |
| b | pipeline | 748 | 1,008 | 3,682 | 2 | 24 % | 31 % | 45 % | 1,866 |
| b | 404 | 1,130 | 5,153 | 24,100 | 94 | 27 % | 34 % | 39 % | 3,018 |

The probe's write took at most 1 % of the slow samples in every run.
Blocking `kevent` calls took none of them: the loop thread was never
waiting on kqueue with the probe's request already written. Run b's
`404` matched 93 of its 94 slow samples; every other run matched all of
them.

- **The loop thread not running** is the largest part of the slow samples
  in four of the six loaded runs (rounds a, b and r2), 31 % to 68 % of
  their time. Inside the loader's steps, which usually take about 1 ms of
  CPU, the wall time grows to tens of ms. In round r2's blocking
  `pipeline` run, the slowest sample took 20.9 ms. The loop thread did
  not run for 19.3 ms of it and used 1.2 ms of CPU. In run b's `404`,
  127 intervals (one event, or the gap between two) each had the thread
  off the CPU for more than 1 ms, 314.8 ms in all. Those intervals counted
  1,075 involuntary and 0 voluntary context switches. Every run counted 0
  voluntary switches in such intervals. That is what preemption of a
  runnable thread gives. Blocking on a lock, a page-in or I/O would count
  voluntary switches, and none was counted in those intervals. The counts
  do not exclude blocks shorter than 1 ms, nor waits that count no switch.
- **After the server's callback** is 27 % to 45 % of the slow samples in
  runs a and b. That time is the probe side: the kernel's delivery, the
  wakeup of the probe's goroutine through Go's netpoller, and its read.
  Round r2's `-spin` runs separate the probe's own pauses. There the
  probe paused for more than 1 ms in 9 of the 15 slow samples of the
  `404` load. In the slowest of them (9.9 ms), it paused for 7.2 ms, after
  the server had sent the response 2.8 ms into the sample. A pause of the
  `-spin` probe can come from Go's scheduler as well as the OS's.
  `syscall.Read` gives up the goroutine's P and takes one back.
- **The server's own work** does not make the maxima. No callback took
  more than 3.0 ms of the loop thread's CPU (the loader's largest steps,
  which include the Lean runtime and the allocator), and no `kevent` call
  more than 38 µs. Over a slow sample's whole span, which can hold several
  callbacks, the loop thread's CPU is the table's 15 % to 27 % of the
  sample. The largest callbacks are up to twice the 1.6 ms that
  `lsrv-parsebench` measured in process for the same step. Their cause was
  not traced; an efficiency core and cache state are candidates.
- **The slow samples come with contention on the host.** In run b's
  `404`, 49 of the 94 slow samples fell in the two seconds `top` saw at
  17 % and 23 % idle CPU. Another process (`fff-mcp`) rose to 78 % and
  167 % CPU in those seconds. None fell in the five seconds before them,
  at 37 % to 66 % idle. The canary, in a process of its own, paused for
  more than 1 ms in 0.03 % to 0.92 % of each loaded run's time. In runs a
  and b, 3, 16, 1 and 14 slow samples overlap such a pause, where chance
  gives 0.0, 0.7, 0.0 and 1.1. Alone on the host for 20 s, outside the
  runs, the canary's largest pause was 1.4 ms. `top` names what used the
  host, not what displaced the loop thread.
- Round r3: with the probe at `GOGC=off` the maxima with a loader were 14
  and 23 ms. With `GOMAXPROCS=2` they were 50 and 80 ms. So the probe
  process's GC and its Go parallelism are not needed for the maxima,
  though this does not show that they add nothing. In the `GOMAXPROCS=2` run
  with no loader, the canary paused for 5.4 % of the run and the probe
  reached 43 ms. The loop thread did not run for 37 ms of that sample and
  used 0.08 ms of CPU.

An earlier version of the trace allocated its buffer after the server
reported ready. That made the first probe of each run with no loader take
10 to 108 ms in rounds r2 and r3; `analyze.py` cannot place it, and it is
left out above. Runs a and b allocate the buffer before.

## What it means

- The maxima traced here, up to 37 ms in runs a and b, are mostly the
  server's loop thread off the CPU, in a way consistent with preemption
  (the switch counts above) on a contended host, and the probe's side
  adds the rest; in run b's `pipeline` the probe's side is the larger
  part. The
  loaded runs' maxima are larger because the loop thread is busy, and so
  runnable, for most of the run. A preemption usually catches it inside a
  step that the probe waits for. No part of the server traced here
  (Lean runtime, allocator, kqueue, zio) ran long enough to account for
  them. Its CPU in a slow sample's span stayed within a few ms. The 76 ms
  of item vhvejg's runs were not traced themselves.
- `bench/fairness`'s maxima, and its p99.9 under contention, measure this
  host's scheduling rather than the server. Its medians and lower
  percentiles, on which item vhvejg's conclusions rest, held: the traced
  runs' medians, 725 to 760 µs (`pipeline`) and 0.92 to 1.13 ms (`404`),
  match the untraced runs' 727 to 744 µs and 1.09 to 1.13 ms.
- Not established here: what an idle host gives (predicted: maxima near
  the largest step's CPU time plus a few hundred µs), Linux, and which
  threads took the cores (no kernel trace without root).
