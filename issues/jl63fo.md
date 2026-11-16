Point issues i35sos and tc5rsx at zig/src/pg.c instead of zig/src/glue.c

Item 6gmafg moved glue.c's PostgreSQL section (ekk_pg, ekk_pg_collect and the
rest of the ekk_pg_* functions) verbatim into zig/src/pg.c, so the pool's glue
test can include it on its own. issues/i35sos.md and issues/tc5rsx.md still
name zig/src/glue.c for that code. Item 6gmafg could not change files under
issues/, so those two references are stale. Fix: name zig/src/pg.c in both.

The pool tests (`zig build test` in zig/, run by bench.sh) were run only on
macOS (kqueue). The Linux acceptance item (53rwgc) should also run them on
epoll.
