Move zio to the commit that fixes issue 927 and retire the StopGate subset contract

The user asked on 2026-11-17 to act on https://github.com/lalinsky/zio/pull/928. The maintainer merged it on 2026-11-17 (merge commit 830564437b2c55583941364db985b4c0746b3dda, zio main at that time): "Fixes #927 ... notify stays lock-free and safe to call from a signal handler. It is now safe to call at any time while the `Async` itself is alive." Deinit disarms every handle and waits out a notifier's wake syscall. So the race of item ho2lwl is an upstream bug, now fixed upstream, and policy Rule 6 retires our supported-subset contract.

Do:
- Pin zio in zig/build.zig.zon to 830564437b2c55583941364db985b4c0746b3dda (hash updated by `zig fetch`).
- Remove the per-loop StopGate (zig/src/serve.zig, from commit 06aba7b) and the subset-contract text next to it and in README "Transport tests"; the signal thread calls `notify` plainly. Keep `Async` alive for as long as a notify may run (the PR's stated requirement), and say where that holds.
- Replace the StopGate tests with a test against the artifact we build that exercises the issue-927 interleaving through zio's own API (a notify racing the loop's end and deinit), forcing the order with synchronization on a positive event, not timing; show it fails with the old pin 9bef33d (or cite zio's own new tests in src/ev/test/async_stress.zig if a test in our tree cannot force the order without reaching into zio internals) and passes with the new one.
- Read zio's changelog between 9bef33d and the new commit for other behavior changes and note them.
- Full ./bench.sh as the gate. Tell ekklesiai.org (consumer) about the new pin in the finish message.
