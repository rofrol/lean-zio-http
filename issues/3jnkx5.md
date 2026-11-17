Deadlines for PostgreSQL queries, connection attempts and shutdown in the Lean server

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item ralqnr (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm: `zig/src/pg.zig` has no deadline on a query or a connect (README "Not bounded yet"). A database that stops answering without closing its sockets holds the HTTP connections waiting on it, and holds the loop's shutdown (`stopCb` waits for in-flight queries), indefinitely. Decide the contract (per-query deadline from the handler, a server-wide one, cancel via PQcancel, what shutdown does with queries in flight) and test it causally (a query held by an advisory lock, a server answering nothing). This is a real external deadline (Rule 10), so its value and reason must be stated next to it.

Question: Should PostgreSQL deadlines be per query from the handler or server-wide, and does a deadline cancel the query (PQcancel) or dispose of the session, and what does shutdown do with queries in flight?
Options: specify completion and shutdown semantics first, then a server-wide deadline with PQcancel | per-query deadline from the handler | dispose of the session on a deadline
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.

Checked 2026-11-17 with sol (consult round 20261117-011832-74e7) under the user's delegation: stays with the user: needs handler completion and connect budgets, whether a cancel is acknowledged (and whether PQcancel itself can block), the transaction or session disposition and shutdown semantics; no value is justified yet.

Related (bx6zh5, closed 2026-11-17): a failed coalesced connect fails every waiting query even when busy healthy connections could serve them later. Keeping waiters instead was rejected because, without query deadlines, an open connection is no evidence of eventual capacity. Once deadlines are decided here, revisit whether waiters may wait for open connections.

Decided 2026-11-17 by the coordinating session with sol (consult round 20261117-090011-f37f), as the user delegated that day. Defaults, all configurable, each an external database budget stated next to its value:
- query completion: 5 s from pool submission to the complete result, queueing included; a handler may ask for another budget up to a configurable ceiling, initially 5 s;
- connect: 5 s from the start of the attempt, enforced around libpq's asynchronous polling, since connect_timeout does not bound that API; a waiter keeps its own earlier query deadline;
- PostgreSQL statement_timeout: 4 s, set on each session before application queries.
Submission, completion, connect failure and expiry are pool events with operation generations. Prove exactly-once handler completion, removal of an expired waiter, that a stale event changes nothing, and that a timed-out session is never reused. On query expiry, fail the handler and dispose of the session without waiting on PQcancel. Answer 504 if no header has been sent yet, otherwise close. A write that was running may have committed, so report an unknown outcome (ycpzlt's signal) and never replay it.
Shutdown stops admission, closes idle connections and lets admitted work finish within its budgets and ytzycm's 10 s drain; when the drain expires, everything still open is disposed of.
After that, revisit bx6zh5: a failed connect may keep its waiters only while healthy busy sessions exist, and only up to those waiters' own deadlines.
Order of commits: pool deadlines and session disposal with database integration tests, then shutdown, then the waiter change.
