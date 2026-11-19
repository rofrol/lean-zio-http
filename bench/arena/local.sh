#!/bin/sh
# bench/arena/local.sh OUT ARENA [ROUNDS]: HttpArena's baseline and pipelined
# profiles on this machine's container runtime (on the M1, OrbStack's arm64
# Linux VM), with the accept delay of every connection and the servers'
# system calls traced (item 6p6tu6; docs/reports/over-5s-tail.md). A labelled stress diagnostic, not a test and not a
# measurement of the VPS: OUT (a new, empty directory) gets the generator's
# output, the traces and summary.txt, one line per sample. ARENA is a checkout
# of https://github.com/MDA2AV/HttpArena at build.sh's commit, for the Go
# entries and the request templates. PERF=1 adds a CPU profile of each lsrv
# sample (OUT/perf-*.data; read it with `perf report` in an image built from
# local.Dockerfile: the run's own images are untagged when it ends,
# linux/run-images.sh).
#
# Builds lsrv-arena (epoll) from the working tree and the Go entries natively
# in linux/Dockerfile's image, gcannon in local.Dockerfile's, then runs
# local-inner.sh in a privileged container (bpftrace and perf need it), with
# the servers and the generator on the same two CPUs, as on the VPS. Needs
# docker and network access.
set -eu
[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: $0 OUT ARENA [ROUNDS]"; exit 2; }
out=$1 arena=$2 rounds=${3:-1}
case $rounds in '' | *[!0-9]*) echo "ROUNDS must be a number"; exit 2 ;; esac
arena_commit=$(sed -n 's/^arena_commit=//p' "$(dirname "$0")/build.sh")
[ -d "$out" ] && [ -z "$(ls -A "$out")" ] || { echo "$out must be an empty directory"; exit 2; }
out=$(cd "$out" && pwd) arena=$(cd "$arena" && pwd)
[ "$(git -C "$arena" rev-parse HEAD)" = "$arena_commit" ] || { echo "$arena is not at $arena_commit"; exit 1; }
cd "$(dirname "$0")/../.."
mkdir "$out/b"

. linux/run-images.sh
git ls-files -z --cached --others --exclude-standard >"$tmp/files"
COPYFILE_DISABLE=1 tar --null -T "$tmp/files" -cf "$tmp/tree.tar"
COPYFILE_DISABLE=1 tar -C "$arena" -cf "$tmp/arena.tar" frameworks/go-stdlib frameworks/go-fasthttp requests
base=lsrv-linux-check:$run_tag
run_image_build "$base" linux
docker run --rm -v lsrv-linux-cache:/home/check/.cache -v "$tmp/tree.tar:/tree.tar:ro" -v "$tmp/arena.tar:/arena.tar:ro" \
  -v "$out/b:/out" "$base" sh -c '
  set -eu
  mkdir src arena && tar --warning=no-unknown-keyword -xf /tree.tar -C src && tar -xf /arena.tar -C arena
  cd src && . bench/lib.sh
  export LIBRARY_PATH=$(pg_config --libdir)
  LSRV_LINUX_BACKEND=epoll lake build lsrv-arena >/out/build.log 2>&1 || { tail -20 /out/build.log; exit 1; }
  cp .lake/build/bin/lsrv-arena /out/lsrv-arena
  for e in go-stdlib go-fasthttp; do (cd ../arena/frameworks/$e && CGO_ENABLED=0 go build -trimpath -o /out/$e main.go); done
  cp -r ../arena/requests /out/'
image=lsrv-arena-local:$run_tag
run_image_build "$image" -f bench/arena/local.Dockerfile bench/arena
docker run --rm --privileged -v "$out/b:/b:ro" -v "$PWD/bench/arena:/s:ro" -v "$out:/out" "$image" \
  sh /s/local-inner.sh /out "$rounds" "${PERF:-0}" lsrv-arena go-stdlib go-fasthttp
