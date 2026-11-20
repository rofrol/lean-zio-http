Wait for perf record's acknowledgement that it records before bench/arena/local-inner.sh runs the load

Found by the review of item cmb7vk (consult round 20261120-181955-c1f5, sol
call d9b50e52 and hydrogen call 684d6cec, both), checked against the code;
it predates cmb7vk.

- `bench/arena/local-inner.sh` starts `perf record -q -F 999 -g -p $pid ... &`
  and goes straight on to the 5 s load and then `kill -INT $pf; wait $pf`.
  Nothing establishes that perf has started recording: the profile can miss
  the start of the load, and a background job of a non-interactive dash
  starts with SIGINT ignored, so a SIGINT that reached perf before it
  installed its own handler would be lost and `wait $pf` would block before
  the server's SIGTERM (a hang of the run). The 5 s load makes this unlikely,
  not impossible (AGENTS.md, Rule 10).
- A positive event exists in perf's documented interface: `perf record -D -1
  --control fifo:CTL,ACK` starts with its events disabled and answers
  `enable` on CTL with `ack` on ACK (perf-record(1), `--control`, `-D`).
  Options: (a) start perf that way under `start_supervised`, send `enable`,
  and wait for `ack` or the supervisor's record of perf's exit, before the
  load; (b) keep it as is, as an accepted limit of the diagnostic. The
  fifo reads need a design that cannot block when perf exits first.
- Same file, the same pattern as the server's check: when bpftrace or perf
  exited and was reaped before the SIGINT, a reused pid would take the
  signal instead of the "exited before SIGINT" branch. Whether to accept
  that for the diagnostic is part of this item.
