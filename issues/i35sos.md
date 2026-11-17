Invalidate the per-connection statement cache after a schema change

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item oo7gdu (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm: `ekk_pg` (zig/src/pg.c) keeps up to 64 prepared statements per connection; a cached plan whose result type changes after DDL fails with 0A000 ("cached plan must not change result type") until the connection is replaced, and the cache is never evicted (README "Statements"). Decide: forget the entry on 0A000/26000 (and answer the query as failed, never resending it), or close the session.

Question: On 0A000/26000, should the pool forget the cached statement and fail the current query without resending it, or close the session?
Options: forget the entry and fail the current query without replay | close the session
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.

Decided 2026-11-17 by the coordinating session with sol (consult round 20261117-011832-74e7), under the user's delegation of the same day to decide the open questions with sol: invalidate the affected cached statement and fail the current query without replay. Recognize the cached-plan failure specifically (not every 0A000), make sure a later prepare cannot collide with a statement still on the server, and test DDL, 26000 and transactions.
