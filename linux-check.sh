#!/bin/sh
# The Linux validation (item ogcdwm): runs ./check.sh, with the transport's
# and the PostgreSQL pool's tests (zig build test) and the database checks on
# a private PostgreSQL cluster, in a Debian container (linux/Dockerfile) on
# this machine's container runtime (docker; on the M1 Mac, OrbStack's Linux
# VM). The loops run on epoll there (zig/build.zig pins it; serve_test.zig's
# "the loops run on the readiness backend ..." checks it). It copies the working tree (tracked files and untracked
# ones git does not ignore) into the container, so it checks uncommitted
# changes too, and leaves nothing of the build on the host but the image and
# the cache volume `lsrv-linux-cache` (Zig's and Go's downloads).
#
# Required at each update of zio (build.zig.zon), with its result recorded
# in the commit (README, "Running"). It is development evidence on the host's
# architecture and the container runtime's kernel, not production
# qualification: the deployed server's epoll suite runs on its own host.
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
echo "backend: epoll (pinned in zig/build.zig, checked by serve_test.zig)"
# The tree goes into the container as an archive built first, so a failure
# of git or tar (a tracked file deleted but not staged, say) stops the
# script instead of hiding behind the container's status. COPYFILE_DISABLE:
# macOS's tar would add AppleDouble `._` files, which the build reads as
# sources.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
git ls-files -z --cached --others --exclude-standard >"$tmp/files"
COPYFILE_DISABLE=1 tar --null -T "$tmp/files" -cf "$tmp/tree.tar"
docker run --rm -v lsrv-linux-cache:/home/check/.cache -v "$tmp/tree.tar:/tree.tar:ro" "$image" \
  sh -c 'mkdir src && tar --warning=no-unknown-keyword -xf /tree.tar -C src && cd src && ./check.sh'
