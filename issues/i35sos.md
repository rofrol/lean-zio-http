Invalidate the per-connection statement cache after a schema change

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item oo7gdu (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm: `ekk_pg` (zig/src/glue.c) keeps up to 64 prepared statements per connection; a cached plan whose result type changes after DDL fails with 0A000 ("cached plan must not change result type") until the connection is replaced, and the cache is never evicted (README "Statements"). Decide: forget the entry on 0A000/26000 (and answer the query as failed, never resending it), or close the session.
