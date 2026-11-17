Decide how to settle zio's undocumented setTimer from a timer's own callback
Done by: the coordinating session

Seen in item uwrdc2 (zio pin 53ed3c377317): pg.zig's `Pool.timerCb` re-arms the pool's own deadline timer through `Pool.rearm`, which calls `Loop.setTimer` on the timer whose callback is running (zig/src/pg.zig, the comment on `Pool.rearm`). zio's `Completion.callback` documentation (src/ev/completion.zig:294-305, https://github.com/lalinsky/zio/pull/929) says the loop does not touch such a completion after the callback returns, and that the callback may `add` it again; `setTimer`'s documentation says only "Set or reset a timer with a new timeout (works immediately, no completion required)" (src/ev/loop.zig:673). That calling it from the timer's own callback is allowed is said only by a comment inside `setTimer`'s body ("rearm from the callback (or after it), never concurrently with the fire", src/ev/loop.zig:681-684). By policy Rule 6 that comment, being implementation, does not settle the contract.

Options for the owner:
- Ask upstream (a comment or issue on https://github.com/lalinsky/zio) to state in `setTimer`'s documentation that it may be called from the timer's own callback; an outward action needing the owner's go.
- Accept the reliance as a supported-subset contract grounded in the pinned implementation, written next to `Pool.rearm`, rechecked at each zio update.
- Change `Pool.rearm` to re-init the timer and `add` it in that case, which the `Completion.callback` documentation covers.
