Make the container scripts' working-tree snapshot skip tracked files deleted from the working tree

Found by item r4q3yu's diff review (consult round 20261119-004751-15c7; sol and hydrogen). linux-check.sh, bench/arena/local.sh and bench/parse/profile.sh copy the working tree into the container with `git ls-files -z --cached --others --exclude-standard` piped to `tar -T`; `--cached` still lists a tracked file deleted in the working tree and not staged, so `tar` fails on the missing path and the run stops before building. Seen in the code, not reproduced.

The same scripts tag their images with fixed names (`lsrv-linux-check`; profile.sh's `lsrv-parse-profile` is `FROM lsrv-linux-check`), so two overlapping runs that change linux/Dockerfile may build and run against different images.

Options:
1. Share one snapshot helper (in bench/lib.sh or a small script) that lists only paths present in the working tree (symlinks kept), and use it in the three scripts.
2. Leave it: a deleted tracked file is staged or restored before such a run.
