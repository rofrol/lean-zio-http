Rerun ./linux-check.sh for the tests and pool changes added since its last recorded run

zig/src/serve_test.zig's header records the last Linux run at commit 7b4e08f (item qgrnr3, 2026-11-18), when serve_test.zig held 40 tests and pg_test.zig 32. Since then serve_test.zig gained 2 tests (6cba7b5, c5ca75; c2be481, 26mde5), pg_test.zig 6 more (38 at af628f0), and the pool changed (6a32c9d faahn4: deadline timer re-armed by re-init and add; 8e83935: a long synchronous chain of completions yields to the loop). None of this has run on epoll or io_uring. AGENTS.project.md asks for a run only at each zio update, so this is a choice for the owner: rerun now and update the header's record, or wait for the next zio update.

Seen by item c6yngw while it made the header state that its counts are those of the named commit.
