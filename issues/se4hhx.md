Should a transport test force a send that stays in the kernel when its write deadline expires?

Seen in znioju: the zio tests in `zig/src/serve_test.zig` check that serve.zig's `expire` asks to cancel the send in flight
only when the send is still running at the expiry (`expectSendClosed`, through `timerSpy`). Test (a) forces the other
case (the send completed in the backend before the timer's callback, so zio's cancel is "too late, no-op"); test (b) and
"a response whose write deadline ends before any next byte arrives" allow either outcome, because loopback frees room in
the server's send buffer asynchronously after a send parks. So no test requires the cancel deterministically; a mutation
that drops the cancel failed in every run seen, but only because the send happened to be still parked. Found by sol in
consult round 20261117-121809-3d51.

A cause seen meanwhile: `requestResponse` sets the client's SO_RCVBUF to 4096 before connect, yet getsockopt on that
client read 314352 on macOS (a temporary diagnostic in znioju), so the client's buffer is not small and the server's
parked send keeps gaining room while the client is not reading; the comments that speak of the client's small receive
buffer (`requestResponse`, `small_buffer`) do not hold there.

Options: (1) find how to make the client's receive window small and fixed on macOS (and Linux), wait for a positive
condition that the client's window is closed, then require the cancel; (2) control the send's readiness at the backend
boundary in the test (e.g. a socket whose peer cannot accept data); (3) accept the conditional check and the mutation
evidence, and correct only the comments about the client's buffer.
