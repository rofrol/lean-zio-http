lsrv-bench prints nothing for over five minutes, so every ./check.sh run trips rr2's quiet wake

Seen in item p5pyti (2026-11-17): in both `./bench.sh` runs, after `lsrv-compare`'s last line ("30000 requests: 27268 verdicts agree, ...") the run printed nothing while `.lake/build/bin/lsrv-bench` ran at 100% CPU (`ps`: etime 05:05 when rr2's `--quiet 300` fired; the first run hit the default 180 s wake at about 03:06 into it). Both runs then went on and exited 0. So every check run under rr2 wakes its agent once for a step that is working, and a real hang in that step looks the same as a normal run.

Question: Should lsrv-bench (Bench.lean) report progress as it goes, for example one line per measured case, so a quiet run means a stuck one?
Options: print one line per case as it is measured | leave it quiet and have runs use a longer --quiet for ./check.sh
