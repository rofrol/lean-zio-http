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
