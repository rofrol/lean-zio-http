Stop discarding bpftrace's and perf's exit statuses in bench/arena/local-inner.sh

The half of item 4fued7 its approval left out (decided 2026-11-20, consult
round 20261120-024100-ec06: "The tracer exit statuses wait for an authorized
VPS run"); item 4fued7 did only the go entries' readiness wait.

- `bench/arena/local-inner.sh`: `wait $bt || true` and
  `[ -z "$pf" ] || { kill -INT $pf; wait $pf || true; }` discard the exit
  statuses of bpftrace and perf record, so a tracer that crashed or failed to
  write its output leaves a run whose trace or profile is missing or cut
  short, and nothing says so. The status each tool gives after the SIGINT the
  script sends is not established (perf record may re-raise SIGINT and end
  with 130; bpftrace's status after SIGINT is unknown). The fix needs those
  statuses measured (a run of each with its own SIGINT, recorded), then the
  expected status checked like the server's in `stop`.
- Same file, bpftrace's attach wait: `kill -0 $bt` ends that wait on
  bpftrace's exit only because dash and bash reap an exited child on SIGCHLD
  (measured in item 4fued7 on dash 0.5.12, Debian trixie), and it reports no
  status. `bench/arena/start-polled.sh`'s supervisor (a subshell that waits
  for the child and records its status) is the pattern the go entries' wait
  now uses; whether bpftrace's wait takes it is part of this item.


Decided by the models under the user's delegation of 2026-11-20 to decide the queue (consult round 20261120-155056-df17; sol call 421584d0, hydrogen call 69355b88), both agreeing: measure the tracers' exit statuses in local.sh's privileged container on the M1, after fbqrqb provides the pinned HttpArena checkout (da3ded60952b); first check that perf and bpftrace run in OrbStack. No VPS run.
