Should the transport tests run on Linux, so the Unix-domain parked-send test is checked on epoll and io_uring?

Seen in se4hhx: the test "a write deadline that ends while its send waits in the kernel cancels that send, which completes
canceled to the closing connection" (`zig/src/serve_test.zig`) relies on a Unix-domain stream socket gaining room only when
its peer reads. It was checked by runs on macOS only (kqueue: `zig build test` 19/19, a diagnostic 50-run stress loop with
0 failures, and a mutation dropping the send's cancel in serve.zig `expire` that the test catches). No Linux run exists in
this repository's checks (`check.sh` cross-builds `libzsrv.a` for Linux but runs no test there); the same gap is noted for
the TCP_NODELAY check (`serve.zig` `openListener`: "Linux is not yet checked by a run there"). On Linux zio may use epoll or
io_uring; under io_uring `sendParked` (completion phase `.running` after `loop.add`) means an SQE was submitted, not that a
syscall returned EAGAIN, so the "positive event" reasoning in the test's comment holds only for the readiness backends.

Options: (1) run `zig build test` on a Linux host (e.g. the owner's x86_64 Guix MacBook) once, record the result next to the
tests, and recheck at each zio update; (2) add a Linux run to `check.sh` (needs a Linux runner, a cost to decide);
(3) leave the tests macOS-only and keep the comments that say so.
