Make the container scripts' working-tree snapshot skip tracked files deleted from the working tree

Found by item r4q3yu's diff review (consult round 20261119-004751-15c7; sol and hydrogen). linux-check.sh, bench/arena/local.sh and bench/parse/profile.sh copy the working tree into the container with `git ls-files -z --cached --others --exclude-standard` piped to `tar -T`; `--cached` still lists a tracked file deleted in the working tree and not staged, so `tar` fails on the missing path and the run stops before building. Seen in the code, not reproduced.

The same scripts tag their images with fixed names (`lsrv-linux-check`; profile.sh's `lsrv-parse-profile` is `FROM lsrv-linux-check`), so two overlapping runs that change linux/Dockerfile may build and run against different images.

Options:
1. Share one snapshot helper (in bench/lib.sh or a small script) that lists only paths present in the working tree (symlinks kept), and use it in the three scripts.
2. Leave it: a deleted tracked file is staged or restored before such a run.

Decided 2026-11-19 by the coordinating session with sol, argon and hydrogen (calls 964aa59f, a7443db6, 932242ab) under the user's delegation: option 1, kept proposed (sol and hydrogen; argon would approve now): low priority while rr2 runs items in fresh worktrees. When taken: reproduce the tar failure with an unstaged deletion first and keep it as the regression test; keep dangling tracked symlinks (test -e || test -L) and NUL-delimited names. The shared image tags are split into their own item, approved.
