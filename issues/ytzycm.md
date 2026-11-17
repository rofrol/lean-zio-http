Per-connection idle, read and write deadlines for the Lean HTTP server

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item 3x4s6c (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.
Seen in queue item 55ewev: README.md, "Production contract", "Not yet": no deadline bounds a connection. A peer can hold a connection slot (`--max-conns`, default 4,096) as long as it likes, trickle a request byte by byte (quadratic parse CPU, see the stateful-parser proposal), and a peer that does not read its response holds the graceful shutdown until the supervisor's SIGKILL (zig/src/serve.zig `stopCb`; README "Shutdown").

Deadlines are designed timers on an external producer (the peer), which policy rule 10 allows with the value and reason stated; their values need the owner's agreement. To decide: which deadlines (idle between requests, head read, body read, write progress, shutdown drain), their values, and whether they live in `Conn.step` as an event (`timedOut`) so the theorems cover them, with zio.ev timers in the loop.

Question: Which per-connection deadlines (idle, head read, body read, write progress, shutdown drain) with which values, and should they be a timedOut event in Conn.step so the theorems cover them?
Options: specify the contract and values first, as a timedOut event in Conn.step | only idle and write-progress deadlines now | none until the Linux runs
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.

Checked 2026-11-17 with sol (consult round 20261117-011832-74e7) under the user's delegation: stays with the user: deadline values are operational requirements; no value is justified yet. Prefer explicit expiry events in Conn.step with theorem coverage once the user sets the values (peer budgets, the supervisor's shutdown deadline).

Decided 2026-11-17 by the coordinating session with sol (consult round 20261117-090011-f37f), as the user delegated that day ("decide with sol"). Contract: explicit expiry events `expired(kind, generation)` in Conn.step. The loop keeps monotonic deadlines and emits these events, and a phase change invalidates older generations. Prove that a stale event changes nothing, that terminal states are kept, that no request is dispatched after a read expiry, and that resources are released once. State explicitly how a completion and an expiry at the same time are ordered. Defaults, all configurable, each an external peer budget stated next to its value:
- keep-alive idle: 60 s from the end of a response to the next request's first byte;
- request head: 10 s absolute, from accept for the first request and from its first byte for later ones; received bytes do not extend it;
- request body: 30 s absolute from head acceptance;
- response write: 30 s absolute from response availability to the last byte handed to the socket;
- shutdown drain: 10 s from shutdown start.
Calibration: nginx's 60 s header, body and send timeouts and 75 s keep-alive; H2O's 10 s header budget. Expiry closes the connection: silently when idle, with no 408 promised on head or body, and bytes already sent stay sent. Split it into commits: configuration with the event contract and proofs, then the loop's timers with tests that force the order. Shutdown drain goes with 3jnkx5's shutdown work.
