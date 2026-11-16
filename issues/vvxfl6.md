The stop notification can wake a loop that has already ended (zio Async.notify racing Loop.deinit)

Found in item lpgru3, which added the transport's controlled-interleaving tests. This is a counterexample to the third contract that item named: "a one-shot `ev.Async` notified from another thread is safe when its loop finishes right after".

What happens: `awaitReadyThenStop` (zig/src/serve.zig) calls `lp.stop.notify()` for each loop from the signal thread. In the pinned zio (9bef33d67424737f864d9131e5b6c0e2526a6704, which is also upstream HEAD on 2026-11-16), `Async.notify` (src/ev/completion.zig:668-681) runs these steps in order:
1. `pending.swap(1)`;
2. `getLoop()`;
3. `Loop.wakeAsync` (src/ev/loop.zig:662). Its `requestWake` sets the async bit and returns true when the loop is asleep in its poll;
4. only then, `backend.wake`, which on kqueue is `kevent(kqueue_fd, NOTE_TRIGGER)`.

Between steps 3 and 4 another event can wake the loop. The loop takes the async bit, runs `stopCb`, finishes its shutdown, and `runLoop` returns and calls `loop.deinit()`, which closes the kqueue. Step 4 then fails with EBADF. zio panics on that error ("kqueue: waker NOTE_TRIGGER failed: BADF"), so the process aborts instead of printing `stopped` and exiting with status 0. If the descriptor number has been reused, the trigger goes to another descriptor instead. The window is the time the signal thread is descheduled between steps 3 and 4. That is short, but nothing excludes it, and under load it is more likely.

Reproducer (run on macOS in lpgru3's worktree as a temporary test in zig/src/serve_test.zig, then removed):
- A thread inits a loop, adds a one-shot `ev.Async` and a `NetRecv` on one end of a socketpair, and runs the loop, then calls deinit.
- The test thread waits until `loop.state.wake_requested == sleeping`.
- It then runs notify's steps 1-3 by hand: `requestWake` returns true.
- It writes a byte to the other end of the socketpair. The loop wakes, dispatches the async, ends and deinits; the test joins the thread.
- It calls `loop.backend.wake(&loop.state)`, step 4. Result: `panic: kqueue: waker NOTE_TRIGGER failed: BADF`.

What it needs from the owner. Per AGENTS.md Rule 6, zio's documentation says only "Notify the loop to wake up and complete this async handle (thread-safe)". It does not say whether a notify may overlap the loop's end and deinit, so whether this is a zio bug or a contract we break is unresolved. Options:
(a) Ask upstream (https://github.com/lalinsky/zio) whether `notify` is meant to be safe when its loop ends concurrently. If it is, this is a bug: fix it in a fork with this reproducer as the regression test and offer the fix upstream. Publishing either is an outward action that needs the owner's go.
(b) If upstream answers that the caller must keep the loop alive until every `notify` has returned, conform to that in serve.zig. For example, a loop deinits only after the signal thread reports that it has notified every loop. That changes the transport's shutdown behavior, so it needs the owner's approval.
(c) Accept the risk and keep it documented. README, "Transport tests", names it as unresolved.

Recommendation (consult round 20261116-183449-f682, sol, under the user's delegation of 2026-11-16): authorize asking upstream (a) first, keeping the reproducer; choose neither a fork fix nor a change of the shutdown until upstream settles the contract. The race itself is demonstrated; only its classification is open.
Question: May I ask zio upstream whether Async.notify must be safe when its loop ends and deinits concurrently?
Options: ask upstream (a) | conform in serve.zig now (b) | accept and keep documented (c)
