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

Decided 2026-11-17 by the coordinating session with sol (consult call 22558d4d) under the user's delegation: a variant of (1), run on the owner's 2010 MacBook (x86_64 Guix System on the LAN) through the macbook-2010 skill. These are diagnostics, not 53rwgc's performance acceptance.
- Run `zig build test` in zig/ with epoll and with io_uring, each selected explicitly and confirmed as the backend in use. Record the kernel, the Zig and zio versions, the commands and the results next to the tests.
- Under epoll, the parked-send test's event must show that the send returned EAGAIN. Under io_uring, a submitted SQE is not enough: find an observable event showing the send is blocked in the kernel, then check that the mutation dropping the cancel is caught. If no such event exists, restrict that test to the readiness backends and skip it under io_uring, stating the reason; the other tests still run there.
- Also run the PostgreSQL pool tests on epoll, against an isolated local database on that machine, never production (taken from 53rwgc).
- Do not make ./check.sh depend on the LAN MacBook. Document the Linux validation command, and require it at each zio update.
