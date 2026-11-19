Move the toolchain to the first nightly with lean4 PR 16562 and set maxPathSegments and maxQueryParams in the H1 adapter

Decided by the user 2026-11-18: approved, the work q2g4am names for 16523's half. https://github.com/leanprover/lean4/pull/16562 (merged 2026-11-18 17:07 UTC as d15bfa70f721, "Closes #16523") adds `maxPathSegments : Option Nat := none` and `maxQueryParams : Option Nat := none` to `H1.Config`; a target over either is refused with 414, like one over `maxUriLength`.

Precondition: a lean4 nightly that contains d15bfa70f721. nightly-2026-11-18 (a2a6b48ad402) does not; check with `gh api repos/leanprover/lean4/compare/d15bfa70f721805968efdfc758b202fabb9c8b95...<nightly sha>` (status "ahead" or "identical"). If none exists yet, end BLOCKED naming the newest nightly checked; do not pin a non-nightly commit.

Work:
- Move lean-toolchain to the first such nightly, as u4moqo did (commit 54cef6b): the full ./check.sh and ./bench.sh, and ./linux-check.sh on epoll and io_uring. The same PR also changes H1 elsewhere (request-line and URI parsing, RFC fixes, redirect handling, connection timeouts through Std.Async.Watchdog, which lsrv does not use). Read its changes to src/Std/Http/Protocol/H1*.lean and Data/URI/Parser.lean against Server/H1Adapter.lean and record in the commit any behavior the adapter's tests or bench/boundary show changing.
- Set both limits in Server/H1Adapter.lean's config. No value was decided: choose N from evidence (other servers' and clients' defaults, for example Go's net/url query parameter limit, and what the H1 tests and docs/memory.md need), state the source next to the constant, and put the choice to the diff review's consult round. Update docs/memory.md ("The adapter's state") with the new per-connection bound measured by lsrv-test and bench/boundary, as tdtseh did.
- Add tests that a target with N+1 segments or parameters gets 414 and one with N is served.

Checked 2026-11-19 06:52 UTC by the coordinating session (the one-shot check decided with sol, argon and hydrogen): the newest leanprover/lean4-nightly tag is nightly-2026-11-18 (a2a6b48ad402), and `gh api repos/leanprover/lean4/compare/d15bfa70f721...a2a6b48ad402` says "behind", so no nightly contains PR 16562 yet. Still blocked; no further check is scheduled. The next session checks again at its start.
