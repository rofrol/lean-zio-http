Deadlines for PostgreSQL queries, connection attempts and shutdown in the Lean server

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item ralqnr (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm: `zig/src/pg.zig` has no deadline on a query or a connect (README "Not bounded yet"). A database that stops answering without closing its sockets holds the HTTP connections waiting on it, and holds the loop's shutdown (`stopCb` waits for in-flight queries), indefinitely. Decide the contract (per-query deadline from the handler, a server-wide one, cancel via PQcancel, what shutdown does with queries in flight) and test it causally (a query held by an advisory lock, a server answering nothing). This is a real external deadline (Rule 10), so its value and reason must be stated next to it.
