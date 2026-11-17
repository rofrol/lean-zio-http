Should serve.zig run on epoll on Linux, or be made correct under io_uring, zio's Linux default?

Seen in ogcdwm (2026-11-17), in a diagnostic run of `zig build test` in zig/ inside an arm64 Debian container under OrbStack (kernel 7.2.12-orbstack, Zig 0.17.1, zio 830564437b2c), with zio's backend forced through `b.dependency("zio", .{ ..., .backend = "io_uring" })`: 7 of serve_test.zig's 22 tests fail (pool tests 31/31 and pg_glue_test pass). Under `epoll` 3 fail, all TCP send-buffer premises (separate item).

Cause, from zio's source (src/ev/backends/linux/io_uring.zig `submitInner`, `.net_send`/`.net_recv`): io_uring queues an SQE at `loop.add` and never tries the syscall first, while the readiness backends do (src/ev/sockreg.zig `submitIo`). So:
- serve.zig `sendParked` (send's phase `.running` after `loop.add`) is true for every send, not only for one whose syscall returned EAGAIN: the readiness poll starts beside every send while Lean watches (test "a response sent at once starts no poll ..." fails at serve_test.zig:1220, `conn.polls` 1, expected 0), the measured cost the README's "PostgreSQL" section avoids.
- Tests relying on inline completion fail: serve_test.zig:822 (expected `.completed`, found `.running`), :967 (expiry reported where the receive should win), :1094 and :1634 (`!writableNow` fails: the send is "parked" while the socket still has room), plus the two partialSend tests (:1382).
- zio's `auto` mode (`Backend(.auto)`, src/ev/backends/linux.zig) prefers io_uring and falls back to epoll only when ring setup fails, so a production server on Linux runs on io_uring today, where none of these premises were checked.

A positive kernel event for "the send waits in the kernel" exists under io_uring: after `io_uring_enter` submits a SEND on a full Unix-domain socket, the ring's `/proc/self/fdinfo/<ring fd>` lists `PollList:` / `op=26` (IORING_OP_SEND, async poll armed after -EAGAIN) with no CQE (probe on the same kernel). fdinfo is a debugging interface, not an ABI; it would need checking on each kernel used.

Options:
(1) Pin the Linux backend to epoll for the library and its tests (`pub const zio_options` in serve.zig's and the test roots, or the build), so the deployed backend is the tested one; io_uring stays unsupported, stated next to the pin.
(2) Make serve.zig correct and efficient under io_uring: replace `sendParked` with a notion that holds for completion backends, and restate the affected tests per backend (the fdinfo event for the parked send).
(3) Keep `auto` and document io_uring as untested.

Decided 2026-11-17 by the coordinating session with sol (consult call 88b30b66) under the user's delegation: option (1). Pin zio's Linux backend to epoll for the library, its tests and the deployed server, and state next to the pin that io_uring is unsupported: these are differences in the backend's semantics, and making serve.zig correct under io_uring is a separate project, not justified for one unused VPS. Check that the pin takes effect, for example by having the test binary report the backend in use. README says which backend runs and why. 53rwgc measures epoll; any io_uring figures are labelled experimental and do not count, since the behaviour differs.
