Stop discarding bpftrace's and perf's exit statuses in bench/arena/local-inner.sh, and end the go entries' readiness loop when the server exits

Seen while doing item p7nicw (2026-11-19):

- `bench/arena/local-inner.sh:86-87`: `wait $bt || true` and `[ -z "$pf" ] || { kill -INT $pf; wait $pf || true; }` discard the exit statuses of bpftrace and perf record, so a tracer that crashed or failed to write its output leaves a run whose trace or profile is missing or cut short, and nothing says so. The statuses each tool gives after the SIGINT the script sends were not checked (perf record may re-raise SIGINT and end with 130; bpftrace's status after SIGINT is unknown). The fix needs those statuses established on the VPS (a run of each with its own SIGINT, recorded), then the expected status checked like the server's in `stop`.
- `bench/arena/inner.sh:114` and `bench/arena/local-inner.sh:54`: in the readiness loop kept for the go entries (which print nothing; polling an external server), `kill -0 "$pid"` succeeds on a server that exited but was not yet reaped (a zombie), so an early exit is reported only after all 5000 curl tries as "did not answer" instead of at once with its status. The loop could check for the child's exit through `wait` on a background reaper (`wait "$pid"` in a subshell that writes the status to a fifo the loop reads), or the server's start could be awaited by `curl --retry-connrefused` bounded by its own retry count; either keeps the external-polling exception and reports the exit status.

Found by the review round 20261119-090027-380f (hydrogen, call 951383b4) and in item p7nicw's own reading.

Decided 2026-11-19 by the coordinating session with sol and hydrogen (consult round 20261119-131820-9a89; calls 2457b2df, db84fdb7) under the user's delegation to decide the next items with the models: needs the owner (VPS load to learn bpftrace's and perf's statuses after SIGINT).
Question: Measure bpftrace's and perf's exit statuses on the VPS and fix local-inner.sh, or only fix the go entries' readiness loop locally?
Options: fix the go entries' loop locally now, the tracer statuses at the next VPS run | measure on the VPS now and fix both (your go for VPS load) | defer both

Decided 2026-11-20 by the coordinating session with sol and hydrogen (consult round 20261120-024100-ec06; calls 722834f8, e97c0537) at the user's request to set the queue with the models: approved into Next, second, limited to the local half (both models): end the go entries' readiness loop when the server exits (its supervisor records the exit; test an early exit and a successful readiness). The tracer exit statuses wait for an authorized VPS run.
