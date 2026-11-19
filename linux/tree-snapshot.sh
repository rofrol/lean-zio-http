#!/bin/sh
# linux/tree-snapshot.sh LIST ARCHIVE: the copy of the working tree that the
# container scripts (linux-check.sh, bench/arena/local.sh, bench/arena/build.sh,
# bench/parse/profile.sh) send into a container. Run at the top of a git work
# tree; writes to LIST the NUL-delimited names of the files it copies and to
# ARCHIVE a tar of exactly those files.
#
# The files are those of the working tree: tracked ones and untracked ones
# git does not ignore. A tracked file deleted but not staged is left out, as
# is one replaced by a directory (tar would copy the directory whole; item
# lmbozk: `git ls-files --cached` lists both, and tar stopped on the missing
# one); a symlink is kept, also when it dangles. The archive is built from
# the list, so the two describe one snapshot: a copy without .git can read
# its file list from LIST (linux-check.sh's MDLINKS_FILES, item gjbmli).
# COPYFILE_DISABLE: macOS's tar would add AppleDouble `._` files, which the
# build reads as sources. Any failure of git, the filter or tar exits nonzero.
# linux/tree-snapshot-test.sh checks it.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 LIST ARCHIVE" >&2; exit 2; }
list=$1 archive=$2
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || { echo "$0: run it at the top of a git work tree" >&2; exit 2; }
# The unfiltered list goes to a file of its own outside the tree, so it is
# never listed itself, and is removed however the script ends.
listed=
trap '[ -z "$listed" ] || rm -f -- "$listed"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
listed=$(mktemp)
git ls-files -z --cached --others --exclude-standard >"$listed"
# The names reach the filter only as operands of its fixed loop; a failed
# write fails it.
xargs -0 sh -c 'for f; do
  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -d "$f" ]; }; then printf "%s\0" "$f" || exit 1; fi
done' sh <"$listed" >"$list"
COPYFILE_DISABLE=1 tar --null -T "$list" -cf "$archive"
