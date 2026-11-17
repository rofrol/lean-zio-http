Should the transport tests' cleanup and leak report get a committed check of their own?

Seen in item ub3d5m (2026-11-17): `Single.deinit` in zig/src/serve_test.zig now drains what a failed test left open and logs a leak at error level, which fails a passing test only because Zig 0.17.1's test runner reports a passing test that logged an error as a failure (lib/compiler/test_runner.zig `log`, `log_err_count`; lib/compiler/Maker/Step/Run.zig, "logged {d} errors"). Both behaviors were shown only by temporary edits (a forced failure: 17 pass, 1 fail instead of 2 pass, 15 fail, 1 crash; a passing test with its stop and `finish` removed: "18 pass; 1 error logs" and the step fails), recorded in the item's commit message. Nothing committed would notice if a Zig update changed the runner's rule or if the drain stopped draining.

Options:
- A build option (for example `zig build test -Dcleanup-demo`) that adds a deliberately failing test and a deliberately leaking passing test, and a script step in `check.sh` that runs it and expects exactly those two reported, by name, with every other test passing. Cost: a build option, a script and a second test run in every gate.
- Recheck by hand at each Zig update only, with a line in the Zig update procedure.
- Leave it as is.

Decided 2026-11-17 by the coordinating session with sol (consult call b0d6691f) under the user's delegation: a variant of (1). Commit the two demonstrations as negative controls behind one explicit command, outside ./check.sh.
- A test that leaks deliberately but otherwise passes: assert the leak diagnostic naming that test and the runner's nonzero exit.
- A test that fails deliberately with connections left open: assert the intended failure, that the drain finished, and that the tests after it ran without cascading failures.
Check those specific outcomes, not merely that the command failed; a compile error must not count as success. The repository's procedure for a Zig update, and for any change to Single.deinit, requires running this command.
