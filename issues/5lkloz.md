Test a connection whose close completes before a retired timer's callback

Seen in ytzycm (f5e3909): `Conn.closeCb` in `zig/src/serve.zig` defers
`destroy` while `retired_arms > 0`, and the retired arm's `timerCb` destroys
the closed connection when it is the last. The retired-arm test in
`zig/src/serve_test.zig` ("a timer whose callback is already on its way ...")
drains the retired callback in the same batch, before the client closes, so
the path where the close finishes first and the retired callback frees the
connection is untested (sol's finding in consult round
20261117-100041-7501).

Work: force a retirement and a close in one poll with the close's completion
dispatched before the retired timer's callback (e.g. retire from a test
timer while a close is already queued), and check that `ekk_free` comes
exactly once, after the retired callback.

Open question: zio's `clearTimer` fails only while the timer sits in the
batch `checkTimers` is dispatching, so the retired callback may always run
before any close completion. Options: (a) write the forced test if such an
order can be built; (b) if it cannot, record the argument next to
`retired_arms` in serve.zig and replace the deferred destroy by an assertion.

Decided 2026-11-17 by the coordinating session with sol (consult round 20261117-101429-40ca), under the user's delegation: first establish, from the source across every close path and reentrant dispatch, whether a close can complete before a retired timer's callback. If it can, option (a): synchronize on retirement and close completion, hold the callback's dispatch explicitly, and check exactly one ekk_free after the last retired callback. If it cannot, write the source-backed ordering argument next to the code and file a Needs-a-decision item before anything like (b). One failed attempt to build the test does not justify removing deferred destruction or replacing it with an assertion.

Established 2026-11-17 by the coordinating session at the user's request: UNREACHABLE under the pinned zio 830564437b2c, read from its source; the key lines were checked by hand. The chain:
- Every serve.zig completion keeps `defer_callback = true` (src/ev/completion.zig:274), so it goes through `dispatchCompletion` → `completions.push` (src/ev/loop.zig:326-331).
- That queue drains first in, first out from a snapshot (loop.zig:1265-1269; queue.zig:43-57, 78-86).
- `checkTimers` only queues timers and runs no callback (loop.zig:1108-1118).
- `clearTimer` returns false only once the timer is completed or being queued (loop.zig:735-743).
- serve.zig disarms before it submits the close (serve.zig:311 before 323; 365, 393).
- Every backend queues the close completion only after it is submitted (kqueue.zig:634-641, linux/epoll.zig:609-616, linux/io_uring.zig:831-837).
So `closeCb` always finds `retired_arms == 0`, and `timerCb`'s `conn.closed` branch (serve.zig:169) is never taken. zio documents none of this ordering: not FIFO dispatch, not that checkTimers runs no callbacks, not that a synchronous close is deferred, not what clearTimer's false means.
Scope now: no forced test, since it cannot be built through zio's public API. Keep the deferred destroy as a defensive guard that relies on no ordering, so no supported-subset contract is needed. Next to `retired_arms` in serve.zig, write that the branch is unreachable under the pinned zio, with the chain above and the zio commit, and that it stays because zio does not document the order. Replacing it with a panic would rely on undocumented behavior and would need the user's approval of a subset contract (policy Rule 6); it is not proposed.
