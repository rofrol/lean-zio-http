Bound the memory of a PostgreSQL result before it is fully received

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item 7wnal6 (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm: `ekk_pg_collect` (zig/src/glue.c) receives each statement result whole through libpq (PQgetResult) before the 1 MiB bound answers 54000, so one large result costs its full size in memory per slot (8 loops x slots). libpq's single-row or chunked-rows mode (PQsetChunkedRowsMode, PostgreSQL 17+) would let the pool stop at the bound. Choose whether to adopt it and how a result over the bound ends the session.
