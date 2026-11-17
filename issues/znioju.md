Test a write deadline expiring during a partial send, in both orders

Seen in ytzycm (f5e3909): the zio tests in `zig/src/serve_test.zig` cover
expiries only around receives, because the fake glue never asks to send
(`ekk_sent` panics: "the fake never asks to send"). The send side of the
contract (serve.zig's `expire` cancels the send in flight; `sendCb` with
`closing` closes without reporting `ekk_sent`; a partial send keeps the
arm and its due time) is exercised only end to end by bench/boundary, and
not in a forced order.

Work: let the fake answer a receive with a send larger than the client's
socket buffer, then force (a) the expiry before a send completion that is
ready and (b) a send completion run before a due expiry, as the receive
tests do (`dueNow` after the socket is writable/readable), and check that a
partial send keeps the arm (same pointer and `timer.deadline`).

Decided 2026-11-17 by the coordinating session with sol (consult round 20261117-101429-40ca), under the user's delegation: approved, both orders. Extend the fake so it requests sends and acknowledges their completions. Show a real partial-send completion and the outstanding remainder through observable hooks; payload size alone proves neither. Force expiry before completion and completion before expiry. Check that partial progress leaves the arm's identity and the absolute deadline unchanged, that expiry cancels the send, that no ekk_sent comes after the close, and that cleanup happens exactly once. Use explicit dispatch barriers and controlled due-state injection, never elapsed-time races.
