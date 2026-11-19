Confirm bench/fairness's probe maxima on an idle host or on Linux?
Item srx6tz (docs/reports/fairness-probe-maxima.md, commit 854fc81) traced the probe's slowest round trips on a contended M1 (load average 7 to 14) and found them mostly the server's loop thread off the CPU, consistent with preemption, with the probe's side adding the rest. It predicts that on an idle host the maxima fall to about the largest step's CPU time plus a few hundred µs, but could not test that: the host never became idle, and without root no kernel trace could name the threads that took the cores. Two further gaps: the largest callbacks used up to 3.0 ms of CPU against 1.6 ms measured in process (cause untraced), and the canary's start is not synchronised with the probe's (runs.sh), which only matters for very short runs.

The choices for the owner:
- A: rerun docs/reports/fairness-probe-maxima/runs.sh on this M1 when nothing else runs (the owner schedules a quiet window), and compare the maxima with the prediction.
- B: run bench/fairness on a Linux host (for example the 2010 MacBook under Guix) with perf sched or bpftrace, which name the preempting threads; needs the trace ported off kqueue.
- C: accept the report as it stands and treat bench/fairness's maxima and p99.9 as host noise in later items, with no further measurement.

Question: Should the probe-maxima prediction be checked, and how?
Options: rerun runs.sh on this M1 in a quiet window you schedule, together with umtm4l's measurement if that is approved, since it needs the same quiet host (recommended) | run on a Linux host with perf sched or bpftrace | accept the report and treat the maxima and p99.9 as host noise

Moved to Needs a decision by the coordinating session, 2026-11-19: every option needs the owner (a quiet window on the shared M1, or another host); the 3.0 ms against 1.6 ms callback gap is to be checked in the same run.
