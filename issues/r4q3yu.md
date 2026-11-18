Build owgate's H1 parse micro-benchmark and local profiling harness, without conclusions

Split from owgate. Decided 2026-11-19 by the coordinating session with sol, argon and hydrogen (calls a4ea9c3c, e2ae593a, f0dde0e8; all three pick this), under the user's request to decide the next tasks with the models while 4bngph waits for a Lean nightly with lean4 PR 16562.

Work: a reusable local micro-benchmark of the H1 adapter's parse path (H1Adapter / Std.Http.Protocol.H1 as lsrv-arena drives it, on HttpArena's baseline and pipelined request shapes), and a script that captures a call-graph profile of it on the M1 and in the Linux container (linux/Dockerfile's image). Smoke-test both on the current toolchain for correctness only.

Limits: no performance conclusions and no README numbers from the current parser (owgate measures PR 16562's parser after 4bngph); do not change H1Adapter, Std.Http or Conn.step; keep the harness isolated so 4bngph's toolchain bump and URI limits land on top without conflict; no VPS runs, no spending, no outward action; no sleep, retry or delay in the scripts (Rule 10). Say in the report how owgate runs the harness after 4bngph.
