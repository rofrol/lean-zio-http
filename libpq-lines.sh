#!/bin/sh
# ./libpq-lines.sh PGSRC: runs the PostgreSQL pool's and the transport's tests
# (`zig build test` in zig/, whose zig/src/pg_glue_test.c runs pg.c against
# the real libpq) against every libpq line the pool supports, not only the
# one pg_config names: the lowest supported release and the newest release
# of each line (README, "PostgreSQL"; zig/src/pg.c, libpq_supported).
# Opt-in, not part of check.sh (decided 2026-11-17, item oruxe4); run it for
# every change to the PostgreSQL glue and at libpq updates (AGENTS.project.md).
#
# PGSRC is a git checkout of PostgreSQL
# (https://git.postgresql.org/git/postgresql.git); the lines and releases are
# its release tags REL_<major>_<minor>, so `git -C PGSRC fetch --tags` first
# to test the newest releases. Every line from 14 up with a release tag is
# tested; a line from 14 up to the newest with no tag of its lowest supported
# release is an error.
# The lowest supported release is 14.6 and 15.1 (single-row mode reset after
# each pipelined query, pg.c), and <major>.0 from 16 on.
#
# Each release's libpq is built from `git archive` of its tag (the checkout
# is not touched) with
#   ./configure --without-readline --without-icu --without-zlib --without-openssl
# and `make install` in src/include and src/interfaces/libpq, into the cache
# directory $LIBPQ_CACHE (default ${XDG_CACHE_HOME:-~/.cache}/lean-zio-http/libpq),
# as the entry REL_<major>_<minor>-<commit, 12 hex digits>. An entry is
# published atomically: built and installed under the cache's tmp.* directory
# (removed on exit), moved to store/, then made visible by creating the entry's
# symbolic link, which a concurrent run cannot overwrite. An interrupted build
# is never used; it can leave an unlinked directory in store/, which no run
# reads and which may be deleted. Delete the whole cache to rebuild every
# entry (after a change of the build commands above, for instance).
#
# For each release it checks that the test process loaded that entry's libpq
# (pg_glue_test prints the file that defines PQlibVersion and the version it
# returns) and prints one line per release; it exits 1 if any release failed.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 PGSRC (a git checkout of PostgreSQL)" >&2; exit 2; }
src=$1
git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || { echo "$src is not a git checkout" >&2; exit 2; }
[ -f "$src/src/interfaces/libpq/fe-exec.c" ] || { echo "$src is not a PostgreSQL checkout" >&2; exit 2; }
src=$(cd -P "$src" && pwd -P)
cd "$(dirname "$0")"

cache=${LIBPQ_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/lean-zio-http/libpq}
case $cache in
  /*) ;;
  *) echo "LIBPQ_CACHE must be an absolute path: $cache" >&2; exit 2 ;;
esac
case $cache in
  *[[:space:]]*) echo "the cache path must not contain white space (configure's --prefix): $cache" >&2; exit 2 ;;
esac
mkdir -p "$cache/store"
tmp=$(mktemp -d "$cache/tmp.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# The releases: "MAJOR MINOR TAG" per line, the lowest supported release and
# the newest release of each line from 14 up (one line when they are the same).
git -C "$src" tag -l 'REL_*' | sed -n 's/^REL_\([0-9][0-9]*\)_\([0-9][0-9]*\)$/\1 \2/p' |
  sort -n -k1,1 -k2,2 | awk '
    $1 >= 14 { if ($1 > top) top = $1; hi[$1] = $2; has[$1 " " $2] = 1 }
    END {
      for (m = 14; m <= top; m++) {
        lo = m == 14 ? 6 : m == 15 ? 1 : 0
        if (!((m " " lo) in has)) { print "missing REL_" m "_" lo; continue }
        print m, lo, "REL_" m "_" lo
        if (hi[m] != lo) print m, hi[m], "REL_" m "_" hi[m]
      }
    }' >"$tmp/releases"
if grep '^missing ' "$tmp/releases" >&2; then echo "these supported releases have no tag in $src" >&2; exit 1; fi
[ -s "$tmp/releases" ] || { echo "$src has no release tag REL_<major>_<minor> from 14 up" >&2; exit 1; }

# build TAG COMMIT ENTRY: builds and publishes the cache entry ENTRY.
build() {
  b="$tmp/${3##*/}"
  mkdir -p "$b/src" "$b/dest"
  git -C "$src" archive -o "$b/src.tar" "$2"
  tar -x -f "$b/src.tar" -C "$b/src"
  rm "$b/src.tar"
  echo "building libpq $1 ($2) into $3"
  if ! (cd "$b/src" && ./configure --prefix="$3" --without-readline --without-icu --without-zlib --without-openssl &&
        make -j"$jobs" -C src/include install DESTDIR="$b/dest" &&
        make -j"$jobs" -C src/interfaces/libpq install DESTDIR="$b/dest") >"$b/build.log" 2>&1; then
    echo "building libpq $1 failed; the end of its log:"; tail -n 30 "$b/build.log"; return 1
  fi
  printf '%s %s\n' "$1" "$2" >"$b/dest$3/source"
  store=$(mktemp -d "$cache/store/${3##*/}.XXXXXX")
  mv "$b/dest$3" "$store/prefix"
  # -n: an entry another run published is a symbolic link to a directory,
  # which ln must not follow (and create the link inside it) but fail on.
  if ! ln -sn "store/${store##*/}/prefix" "$3" 2>/dev/null; then
    # Another run published it first; use that one.
    rm -rf "$store"
    [ -f "$3/source" ] || { echo "$3 exists but is no complete entry"; return 1; }
  fi
  rm -rf "$b"
}

lean_prefix=$(lean --print-prefix)
failed=0
while read -r major minor tag; do
  commit=$(git -C "$src" rev-parse "$tag^{commit}")
  entry="$cache/$tag-$(printf '%s' "$commit" | cut -c1-12)"
  if [ ! -f "$entry/source" ]; then
    if [ -L "$entry" ] || [ -e "$entry" ]; then echo "$entry exists but is no complete entry; delete it" >&2; exit 1; fi
    build "$tag" "$commit" "$entry"
  fi
  version=$((major * 10000 + minor))
  log="$tmp/test-$tag.log"
  status=0
  (cd zig && zig build test -Dlean-include="$lean_prefix/include" -Dpq-include="$entry/include" \
    -Dlean-lib="$lean_prefix/lib/lean" -Dpq-lib="$entry/lib") >"$log" 2>&1 || status=$?
  # The loaded file, resolved, must be in the entry's lib directory.
  loaded=$(sed -n 's/^pg_glue_test: libpq \([0-9]*\) loaded from //p' "$log")
  got=$(sed -n 's/^pg_glue_test: libpq \([0-9]*\) loaded from .*/\1/p' "$log")
  want_dir=$(cd -P "$entry/lib" && pwd -P)
  loaded_dir=""
  if [ -n "$loaded" ] && [ "$(printf '%s\n' "$loaded" | wc -l)" -eq 1 ] && [ -e "$loaded" ]; then
    loaded_dir=$(cd -P "$(dirname "$loaded")" && pwd -P)
  fi
  if [ "$status" = 0 ] && [ "$got" = "$version" ] && [ "$loaded_dir" = "$want_dir" ]; then
    echo "ok   $tag ($commit): libpq $got from $loaded"
  else
    failed=1
    echo "FAIL $tag ($commit): zig build test exited $status; loaded ${got:-no version} from ${loaded:-nothing printed}, expected $version from $want_dir; its output:"
    cat "$log"
  fi
done <"$tmp/releases"
exit "$failed"
