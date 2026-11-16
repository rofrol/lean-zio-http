Per-connection idle, read and write deadlines for the Lean HTTP server

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item 3x4s6c (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.
Seen in queue item 55ewev: README.md, "Production contract", "Not yet": no deadline bounds a connection. A peer can hold a connection slot (`--max-conns`, default 4,096) as long as it likes, trickle a request byte by byte (quadratic parse CPU, see the stateful-parser proposal), and a peer that does not read its response holds the graceful shutdown until the supervisor's SIGKILL (zig/src/serve.zig `stopCb`; README "Shutdown").

Deadlines are designed timers on an external producer (the peer), which policy rule 10 allows with the value and reason stated; their values need the owner's agreement. To decide: which deadlines (idle between requests, head read, body read, write progress, shutdown drain), their values, and whether they live in `Conn.step` as an event (`timedOut`) so the theorems cover them, with zio.ev timers in the loop.

Question: Which per-connection deadlines (idle, head read, body read, write progress, shutdown drain) with which values, and should they be a timedOut event in Conn.step so the theorems cover them?
Options: specify the contract and values first, as a timedOut event in Conn.step | only idle and write-progress deadlines now | none until the Linux runs
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.
