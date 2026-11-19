Decide whether to bound the work one Conn.step does for a connection's pipelined requests

Measured by item vhvejg (docs/reports/full-buffer-step.md, at 5dfb004 against 0164ce4, the commit before 9c774f0, M1): since 9c774f0 (item paarzq) `Conn.gather` answers every pipelined request in the buffer that fits in one send (`maxResponseBytes`, 65,536 bytes) in one `Conn.step`. On a buffer full of 25-byte requests that is 512 responses in one step of about 1.6 ms (lsrv-parsebench's `full` section; the suffix copies are about 0.1 ms of it). A probe connection on the same one-loop lsrv-arena (bench/fairness/run.sh) now has a median round trip of 0.73 to 1.1 ms and a 99th percentile of 0.9 to 1.6 ms beside one such loader, against 40 to 50 µs before 9c774f0; the loader gets 7 to 10 times the responses per second (about 230,000 to 280,000 against about 30,000).

The choice for the owner (a change to `Server.Conn`, so it needs approval):

1. Accept it: one pipelining connection may hold its loop for up to `maxResponseBytes` / (smallest response) requests of work per step, about 1.6 ms for App.Arena on the M1, and several such connections on one loop add up; record that in docs/production-contract.md.
2. Bound `gather` by a request count or a byte count of consumed input per step (for example 16 or 64 requests), trading part of the pipelined throughput for a shorter wait of other connections; measure both with lsrv-parsebench's `full` section and bench/fairness.
3. Remove the suffix copies (an `Adapter` that takes an offset into the buffer): measured to save only about 0.1 ms of the 1.6 ms step, so it does not address the wait; not recommended on fairness grounds.
