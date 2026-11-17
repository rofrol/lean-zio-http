Bound the memory of a PostgreSQL result before it is fully received

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item 7wnal6 (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm: `ekk_pg_collect` (zig/src/pg.c) receives each statement result whole through libpq (PQgetResult) before the 1 MiB bound answers 54000, so one large result costs its full size in memory per slot (8 loops x slots). libpq's single-row or chunked-rows mode (PQsetChunkedRowsMode, PostgreSQL 17+) would let the pool stop at the bound. Choose whether to adopt it and how a result over the bound ends the session.

Question: Should results be received incrementally (libpq chunked-rows mode, PostgreSQL 17+) with the session disposed of on overflow, or keep whole-result buffering?
Options: incremental with session disposal on overflow, after a compatibility review | keep whole-result buffering and document the cost
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.

Decided 2026-11-17 by the coordinating session with sol (consult round 20261117-011832-74e7), under the user's delegation of the same day to decide the open questions with sol: investigation only: compare single-row and chunked-rows modes across the libpq versions supported, including oversized single fields and rows and libpq's transient buffering, and propose an overflow and session contract as a new Needs-a-decision item. No implementation in this item.
