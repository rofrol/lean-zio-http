Open the zio PR with the accept documentation wording asked for in issue 937
Done by: the coordinating session

The zio maintainer asked for a PR with the wording change proposed in https://github.com/lalinsky/zio/issues/937 (comment https://github.com/lalinsky/zio/issues/937#issuecomment-7020153895); the user passed that comment on 2026-11-20 as the go. Fork lalinsky/zio under the user's account, branch from zio's main, change only the doc comment of Server.accept (src/net.zig) and the comment above errnoToAcceptError (src/os/net.zig), run zio's build of the changed files, and open the PR referencing 937.

Progress 2026-11-20: forked as https://github.com/rofrol/zio and pushed branch docs-accept-reset-in-queue (b810de1, on zio's main 6c718b8): the three doc comments only, `zig fmt --check` and `zig ast-check` pass. Opening the PR (`gh pr create -R lalinsky/zio --head rofrol:docs-accept-reset-in-queue`, title "net: say that Linux and macOS accept a connection reset while queued", body: docs only, reproducer in #937, Closes #937) was blocked by the auto-mode classifier as communication the user had not explicitly sanctioned; not retried.

Question: Open the PR on lalinsky/zio from rofrol:docs-accept-reset-in-queue?
Options: yes, open it as prepared | open it yourself from https://github.com/rofrol/zio/pull/new/docs-accept-reset-in-queue | drop it and delete the branch
