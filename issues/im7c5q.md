Should dusty-hello give dusty the real zio module instead of its stub?

Seen while moving dusty-hello's zio pin (item grjqox, 2026-11-17).
`dusty-hello/build.zig:5-9` adds `zio` only to dhello's own module; it never
calls `dusty.module("dusty").addImport("zio", zio.module("zio"))`. dusty
0.6.0 (pinned 96e117fed9f2) gives its module an anonymous `zio` import, the
stub `src/stubs/zio.zig` (`is_stub = true`), and its `build.zig` comment says
"Apps using the zio runtime override it so timeouts use zio.AutoCancel
instead". So the dusty side of `./bench.sh` runs on the zio runtime
(`rt.io()`) but with dusty's portable std.Io timeout watchdog
(`src/deadline.zig`), not the setup dusty documents for zio applications.

Options:
1. Add the `addImport` line so dusty-hello is the configuration dusty
   documents for zio users, and record whether the numbers move.
2. Keep the stub and say in README ("dusty-hello/") that the comparison runs
   dusty with its portable watchdog.

Decided 2026-11-17 by the coordinating session with sol (consult call f4ac61ad) under the user's delegation: option 1. Add the addImport line and check that dusty resolves the real zio (not `is_stub`) and uses zio.AutoCancel. Rerun both servers under the same conditions, and record the change with the numbers before and after in README "dusty-hello/", even if the difference is negligible.
