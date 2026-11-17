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
