#!/bin/sh
# The check of linux/tree-snapshot.sh (item lmbozk), which ./check.sh runs; it
# needs only git and tar. In a scratch repository it first shows that the
# unfiltered list (`git ls-files --cached --others`) still names a tracked
# file deleted but not staged and that tar fails on that list, the failure
# the snapshot exists to avoid; then it takes a snapshot and checks that the
# list and the unpacked archive hold exactly the working tree's files: names
# with a space, a newline or a leading dash, a dangling symlink and one to a
# directory, an untracked file, and a file inside a directory that replaced a
# tracked file; not the deleted file, the replaced one or an ignored one.
set -eu
snapshot=$(cd "$(dirname "$0")" && pwd)/tree-snapshot.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
nl='
'
repo=$scratch/repo
mkdir -p "$repo/sub"
cd "$repo"
git init -q .
printf 'ignored.txt\n' >.gitignore
for f in kept.txt gone.txt dir-now -e "with space" "new${nl}line" sub/a.txt; do printf 'x\n' >"$f"; done
ln -s missing dangling
ln -s sub linkdir
# Staged, not committed: the index is all `git ls-files --cached` reads, and
# no commit means no user hook or signing setting takes part.
git add -A
rm gone.txt dir-now
mkdir dir-now
printf 'x\n' >dir-now/x
printf 'x\n' >untracked.txt
printf 'x\n' >ignored.txt

# The trigger: the unfiltered list names gone.txt, and tar stops on that list
# because of gone.txt alone: with it restored, the same list archives.
git ls-files -z --cached --others --exclude-standard >"$scratch/unfiltered"
tr '\0' '\n' <"$scratch/unfiltered" >"$scratch/unfiltered.lines"
if ! grep -qx gone.txt "$scratch/unfiltered.lines"; then
  echo "git ls-files --cached no longer lists a tracked file deleted but not staged: rewrite this check"; exit 1
fi
if COPYFILE_DISABLE=1 tar --null -T "$scratch/unfiltered" -cf "$scratch/unfiltered.tar" 2>/dev/null; then
  echo "tar no longer fails on a listed file that is missing: rewrite this check"; exit 1
fi
printf 'x\n' >gone.txt
COPYFILE_DISABLE=1 tar --null -T "$scratch/unfiltered" -cf "$scratch/unfiltered.tar"
rm gone.txt

"$snapshot" "$scratch/list" "$scratch/tree.tar"
printf '%s\0' .gitignore -e dangling dir-now/x kept.txt linkdir "new${nl}line" sub/a.txt untracked.txt "with space" \
  >"$scratch/expected.unsorted"
sort -z "$scratch/expected.unsorted" >"$scratch/expected"
sort -z "$scratch/list" >"$scratch/listed"
if ! cmp -s "$scratch/expected" "$scratch/listed"; then
  echo "tree-snapshot.sh listed:"; tr '\0' '\n' <"$scratch/list"; exit 1
fi
mkdir "$scratch/out"
tar -xf "$scratch/tree.tar" -C "$scratch/out"
# Each producer writes a file of its own, so set -e sees its status.
(cd "$scratch/out" && find . ! -type d -print0) >"$scratch/found"
sort -z "$scratch/found" >"$scratch/unpacked"
xargs -0 sh -c 'for f; do printf "./%s\0" "$f"; done' sh <"$scratch/expected" >"$scratch/prefixed"
sort -z "$scratch/prefixed" >"$scratch/expected-unpacked"
if ! cmp -s "$scratch/expected-unpacked" "$scratch/unpacked"; then
  echo "tree-snapshot.sh's archive holds:"; tr '\0' '\n' <"$scratch/unpacked"; exit 1
fi
[ -L "$scratch/out/dangling" ] && [ "$(readlink "$scratch/out/dangling")" = missing ] ||
  { echo "the archive does not keep the dangling symlink"; exit 1; }
[ -L "$scratch/out/linkdir" ] && [ "$(readlink "$scratch/out/linkdir")" = sub ] ||
  { echo "the archive does not keep the symlink to a directory as a symlink"; exit 1; }
echo "tree-snapshot.sh: the list and the archive hold the working tree's files"
