Quiet bench/arena/local.sh's tar warnings and "Terminated" lines, and name where its HttpArena checkout lives

Seen in item fbqrqb's run of `bench/arena/local.sh` on the M1 (2026-11-20, commit 66b9853, HttpArena da3ded60952b, OrbStack), which ended 0 with every sample's summary line:

- 95 of the log's lines are `tar: Ignoring unknown extended header keyword 'LIBARCHIVE.xattr.com.apple.provenance'`: macOS's bsdtar writes the provenance xattr into `$tmp/arena.tar` even with `COPYFILE_DISABLE=1`, and the container's `tar -xf /arena.tar -C arena` (bench/arena/local.sh, the first `docker run`) lacks the `--warning=no-unknown-keyword` that the tree.tar extraction beside it has. Harmless (GNU tar ignores the header), but it buries the build's real messages.
- Four `Terminated` lines, one per go entry's sample: the supervisor subshell of `start_polled` (bench/arena/start-polled.sh) has its stdout sent to /dev/null but not its stderr, and dash reports there that the child it waited for died of SIGTERM, the expected end that local-inner.sh checks as status 143.
- No place names where the pinned HttpArena checkout lives on this machine. Item fbqrqb made it at `${XDG_CACHE_HOME:-~/.cache}/lean-zio-http/httparena` (a depth-1 fetch of da3ded60952b), next to the PostgreSQL checkout AGENTS.project.md names; item cmb7vk needs it. Whether to write that location into docs/running.md (with how to make it) is the owner's choice.

Options: add `--warning=no-unknown-keyword` to that extraction; send the supervisor's stderr to the server's log or leave it; document the checkout's location or keep it per run.
