Act on leanprover/lean4's answers to the Std.Http questions 16522 and 16523

Posted 2026-11-17 by the coordinating session from the user's gh account, at the user's go (items mxzlsx and jqzv42, drafts by lgxdi7 in docs/upstream/):
- https://github.com/leanprover/lean4/issues/16522: is an unfinished field line or start line meant to be parsed incrementally across `Machine.feed` calls? This decides mxzlsx. If a maintainer calls it a bug, follow the fork path of policy Rule 6: a fork from the pinned nightly, a regression test that fails before the fix, and a PR. If a maintainer calls it a limitation, quote the statement next to Server/H1Adapter.lean's config. Until then the item stays blocked, with no local workaround.
- https://github.com/leanprover/lean4/issues/16523: an RFC for `maxPathSegments` and `maxQueryParams` in H1.Config. This decides jqzv42. If it is accepted and released, set both limits in Server/H1Adapter.lean and update README "Memory". If it is declined, the per-connection bound stays at what maxUriLength gives, and the user decides whether to lower the connection cap.

Waits for a maintainer's answer, so it is not approved work until one arrives. Check both issues when the session starts and at each toolchain update (u4moqo).
