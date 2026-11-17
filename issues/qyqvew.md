Should a pipelined head's budget also start at its first byte while the previous request's query runs?

Seen in item dv6ikn (commits 0302eac, 8d76550): the loop learns of a later request's first byte from leftover buffered bytes or from the readiness poll beside a parked send (zig/src/serve.zig `apply`, `sendParked`). While a request waits for its PostgreSQL query, nothing watches the socket, so bytes arriving then are seen only when the response's write starts: that head's budget starts late by at most the query's duration (README "Deadlines"). Queries have no deadline yet (README "Not yet"), so the lateness is bounded only by the query.

Options:
- (a) Leave it until queries get a deadline; then the lateness is bounded by that deadline.
- (b) Keep the readiness poll while querying too (Lean's state would watch in the querying phase with an empty buffer, and an `arrived` there would set a head start carried into the response's write), at the cost of one poll per query request, which bench.sh showed costs about 13 us of CPU per request on macOS when done per response (dv6ikn, before 8d76550).
- (c) Stamp the first byte from the kernel's receive timestamp (SO_TIMESTAMP) when the bytes are finally read, if the platform supports it on TCP: no extra syscalls, but platform-dependent; whether macOS and Linux give it for TCP stream data was not checked.
