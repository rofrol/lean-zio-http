Open the zio PR with the accept documentation wording asked for in issue 937
Done by: the coordinating session

The zio maintainer asked for a PR with the wording change proposed in https://github.com/lalinsky/zio/issues/937 (comment https://github.com/lalinsky/zio/issues/937#issuecomment-7020153895); the user passed that comment on 2026-11-20 as the go. Fork lalinsky/zio under the user's account, branch from zio's main, change only the doc comment of Server.accept (src/net.zig) and the comment above errnoToAcceptError (src/os/net.zig), run zio's build of the changed files, and open the PR referencing 937.
