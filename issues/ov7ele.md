Decide how to report Zig's "failed command:" line printed for a passing test step (an upstream bug)

Needs a decision. Found in item yg56hu (2026-11-19), which was approved as an investigation only: "if it is an upstream bug, stop and record a Needs-a-decision item (Rule 6: no local stderr workaround, an upstream report needs the owner's go)".

## What happens

Every `zig build test` in `./check.sh` prints the stderr of serve_test, followed by `failed command: .../serve_test --cache-dir=... --seed=... --listen=-`, even though the step passes. The stderr comes from the accept back-off test (`zig/src/serve.zig:957`).

## Cause (traced in Zig 0.17.1, tag 0.17.1 = be248cc1fdc3cc654f9ec8ba68514bcb93b204fe)

- `lib/zig/compiler/Maker/Step/Run.zig`, `make()`: the helpers that spawn the child always set `step.result_failed_command` before running it (`spawnChildAndCollect`, Run.zig:2696-2704: "We have to set the failed command here regardless of whether this function returns an error because only after this function returns does the logic determine whether the child process termination was success or failure.").
- The end of `make()` then clears it (Run.zig:733-737: "Here we free the memory since the step has succeeded." `step.clearFailedCommand(gpa);`). The early return in the `if (!any_discovered_inputs)` branch (Run.zig:580-607) is the path every Run step without dep-file outputs takes, `addRunArtifact` of a test included, and it returns at line 607 without that clear.
- `Step.zig:68-69` documents the field: "If the step is failed and this field is populated, this is the command which failed. This field may be populated even if the step succeeded."
- `Maker.zig:2894` prints a step's messages "No matter the result". `printErrorMessages` (Maker.zig:3393-3400) then prints `failed command: <cmd>` whenever the field is set, without checking that the step failed. Its own documentation says the field names a failed command only when the step failed, so the printer contradicts it.

Upstream master (8336234223b160d5b81a716f40c0164d21540c1f, 2026-11-19) still has the same early return (Run.zig:584-611), the same field documentation (Step.zig:69-70) and the same unconditional printer (Maker.zig:3743-3750). A search of upstream issues on Codeberg ("failed command" with passing, success and stderr) found no report. https://codeberg.org/ziglang/zig/issues/35958 is a different bug: output of passing tests shown with a failing one.

## Reproducer and fix (checked locally, not published)

A minimal project: `build.zig` with `b.addRunArtifact(b.addTest(...))` and one test that calls `std.debug.print("hello from a passing test\n", .{})`. Running `zig build test` with Homebrew's Zig 0.17.1 exits 0 and prints:

```
test
+- run test stderr
hello from a passing test
failed command: ./.zig-cache/o/<hash>/test --cache-dir=./.zig-cache --seed=0x... --listen=-
```

I copied 0.17.1's lib directory, added `step.clearFailedCommand(gpa);` before the `return;` at Run.zig:607, and ran the same project with `ZIG_LIB_DIR` pointing at the copy. It printed the stderr without the `failed command:` line and still exited 0. A fix could go in either place: clear the field on that return, or have `printErrorMessages` print it only for a failed step. Upstream chooses which.

## Options (the owner decides; Rule 6 allows no local stderr workaround)

1. Report it upstream as a Codeberg issue with the reproducer, the quoted passages and the one-line fix, then wait for a release with the fix. Nothing changes here except possibly a note (option 3). Publishing the issue needs the owner's go.
2. Rule 6's full path: fork ziglang/zig under the owner's account on a branch from 0.17.1, add a regression test that fails before the fix, offer a PR, and build this project with the forked Zig. Costs: this project gets Zig from Homebrew and in `linux/Dockerfile`, so a forked compiler means building and pinning our own toolchain (docs/forks.md, `pin/` tags), and keeping it rebased until a release fixes it. That is heavy for a cosmetic log line. The PR can be offered without switching to the fork.
3. Add a note to docs/running.md saying that Zig 0.17.1 labels a passing test step's stderr "failed command:", with a link to this upstream bug, so a log reader knows this line in a passing run is not a failure. This changes no code, so it is no workaround. It can be combined with 1.
4. Leave it as it is.

Recommendation: 1 and 3. Also report the fix as a PR if the owner wants it upstream sooner. Do not switch the toolchain to a fork.

Question: How should Zig's "failed command:" line for a passing test step be handled?
Options: report it upstream on Codeberg and add a note to docs/running.md (recommended) | report upstream only | fork Zig, offer a PR and build with the fork | leave it as it is
