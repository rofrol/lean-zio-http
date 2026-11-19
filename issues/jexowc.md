Settle the dependency assumptions that rest on upstream code rather than upstream documentation (Rule 6)

Found by the comment audit the user asked for on 2026-11-19 (findings checked against the code by the coordinating session). Each relies on what a pinned dependency's code does, not on a quoted documented contract or maintainer statement, and DECISIONS.md holds no owner-approved supported-subset contract for it:
- zig/src/glue.c:12 declares `lean_initialize_thread`/`lean_finalize_thread` itself ("Exported by libleanrt ... but not declared in lean.h"); docs/modules.md repeats it; no upstream statement that they are supported API.
- zig/src/serve.zig:1216-1237: accept callbacks run on their own loop's thread because the loops share no zio LoopGroup; the comment says zio's docs say only "Called on the loop's thread" and "this rests on the code cited above" (guarded by serve_test checks and `pg.ownLoop`).
- zig/src/pg.zig:60: the pool polls a dup of libpq's socket because of zio's registry behaviour, cited without a pin or file:line.
- zig/src/pg.zig:185: MSG_PEEK receive instead of NetPoll, justified by an uncited, unmeasured claim about NetPoll's cost.
- test/retained.c:13: hand-declares calloc/realloc/abort and mi_usable_size, relying on Lean's runtime using mimalloc.
- lakefile.lean:19-68 (`glibcVersion`, `zsrvTarget`): reads the toolchain's glibc version by scanning libc.so's bytes, because Lean's toolchain drops the version from the file name.
For each: the owner either approves a supported-subset contract (written next to the code, marked not an upstream guarantee, rechecked at each update), or the question goes upstream as an outward action the owner approves, or the code stops relying on it.
