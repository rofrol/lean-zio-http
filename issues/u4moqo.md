Move the toolchain to the first nightly with lean4 PR 16417 (Std.Http RFC fixes)

Relayed on 2026-11-16 by the ekklesiai.org session (ekklesiai-org-8f), from the user: https://github.com/leanprover/lean4/pull/16417 ("fix: make Std.Http follow RFC 9110, RFC 9112 and RFC 3986 in twelve ..."), merged 2026-11-16T20:29:37Z as 13921a64bf71, closes leanprover/lean4 issue 16479; it changes src/Std/Http/Protocol/H1.lean and its Parser, Reader and Writer. `Server.H1Adapter` runs on `Std.Http.Protocol.H1` with leanprover/lean4:nightly-2026-11-14, which predates it.
Checked 2026-11-16 (`gh release list -R leanprover/lean4-nightly`): the newest nightly is nightly-2026-11-16, built 11:06Z, before the merge; so no nightly contains it yet. A toolchain move changes the dependency the core contracts' adapter runs on and the consumer (ekklesiai.org's site/lean-toolchain) has to follow it.
Do, once approved and once a nightly contains 13921a64bf71: move lean-toolchain, run ./bench.sh (the H1 comparison against the hand-written parser and the corpus show behavior changes), record in README any changed parser behavior, then tell ekklesiai.org the commit.
Question: Should lean-zio-http move to the first nightly that contains PR 16417?
Options: yes, once that nightly exists, with ./bench.sh and the parser comparison as the check | wait for a release candidate | stay on nightly-2026-11-14
