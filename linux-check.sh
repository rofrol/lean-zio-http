#!/bin/sh
# The Linux validation (item ogcdwm): runs ./check.sh, with the transport's
# and the PostgreSQL pool's tests (zig build test) and the database checks on
# a private PostgreSQL cluster, in a Debian container (linux/Dockerfile) on
# this machine's container runtime (docker; on the M1 Mac, OrbStack's Linux
# VM), twice: with the loops on epoll and on io_uring (LSRV_LINUX_BACKEND,
# check.sh; serve_test.zig's "the loops run on the backend the build chose
# ..." checks each; item wi7efy). The io_uring run has the container's seccomp
# filter off (`--security-opt seccomp=unconfined`): docker's default profile
# refuses io_uring_setup, so zio's loop would not start. It copies the working
# tree (tracked files and untracked
# ones git does not ignore) into the container, so it checks uncommitted
# changes too, and leaves nothing of the build on the host but the image and
# the cache volume `lsrv-linux-cache` (Zig's and Go's downloads).
#
# Required at each update of zio (build.zig.zon), with its result recorded
# in the commit (README, "Running"). It is development evidence on the host's
# architecture and the container runtime's kernel, not production
# qualification: the deployed server's suite runs on its own host, on the
# backend it is built with.
# It needs network access (Debian's packages, the pinned toolchains, zio and
# the Go modules). Any failure stops it with a nonzero status.
set -eu
cd "$(dirname "$0")"
image=lsrv-linux-check
nightly=$(sed -n 's/^ARG LEAN_NIGHTLY=//p' linux/Dockerfile)
if [ "$(cat lean-toolchain)" != "leanprover/lean4:$nightly" ]; then
  echo "lean-toolchain names $(cat lean-toolchain); linux/Dockerfile installs $nightly: update the Dockerfile"; exit 1
fi
docker build -q -t "$image" linux >/dev/null
# The run's environment, for the record.
docker run --rm "$image" sh -c '
  echo "architecture: $(uname -m)"; echo "kernel: $(uname -r)"
  echo "debian: $(cat /etc/debian_version)"; echo "zig: $(zig version)"
  echo "lean: $(lean --version)"; echo "go: $(go version)"
  echo "libpq: $(pg_config --version)"; echo "postgres: $(postgres --version)"'
echo "zio: $(sed -n 's/.*lalinsky\/zio#\([0-9a-f]*\)".*/\1/p' zig/build.zig.zon)"
# The tree goes into the container as an archive built first, so a failure
# of git or tar (a tracked file deleted but not staged, say) stops the
# script instead of hiding behind the container's status. COPYFILE_DISABLE:
# macOS's tar would add AppleDouble `._` files, which the build reads as
# sources.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
git ls-files -z --cached --others --exclude-standard >"$tmp/files"
COPYFILE_DISABLE=1 tar --null -T "$tmp/files" -cf "$tmp/tree.tar"
for backend in epoll io_uring; do
  echo "backend: $backend (LSRV_LINUX_BACKEND, checked by serve_test.zig)"
  seccomp=
  [ "$backend" = io_uring ] && seccomp="--security-opt seccomp=unconfined"
  # $seccomp is unquoted on purpose: empty, or two fixed words.
  docker run --rm $seccomp -e LSRV_LINUX_BACKEND="$backend" -v lsrv-linux-cache:/home/check/.cache \
    -v "$tmp/tree.tar:/tree.tar:ro" "$image" \
    sh -c 'mkdir src && tar --warning=no-unknown-keyword -xf /tree.tar -C src && cd src && ./check.sh'
done
