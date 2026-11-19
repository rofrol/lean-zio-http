#!/bin/sh
# The Linux validation (item ogcdwm): runs ./check.sh, with the transport's
# and the PostgreSQL pool's tests (zig build test) and the database checks on
# a private PostgreSQL cluster, in a Debian container (linux/Dockerfile) on
# this machine's container runtime (docker; on the M1 Mac, OrbStack's Linux
# VM), twice: with the loops on epoll and on io_uring (LSRV_LINUX_BACKEND,
# check.sh; serve_test.zig's "the loops run on the backend the build chose
# ..." checks each; item wi7efy). The io_uring run has the container's seccomp
# filter off (beside the flag below). It copies the working tree (tracked
# files and untracked ones git does not ignore) into the container, so it
# checks uncommitted
# changes too, and leaves nothing of the build on the host but the cache
# volume `lsrv-linux-cache` (Zig's and Go's downloads) and docker's build
# cache: the image is tagged for this run only and untagged when it ends
# (linux/run-images.sh).
#
# Required at each update of zio (build.zig.zon), with its result recorded
# in the commit (docs/running.md). It is development evidence on the host's
# architecture and the container runtime's kernel, not production
# qualification: the deployed server's suite runs on its own host, on the
# backend it is built with.
# It needs network access (Debian's packages, the pinned toolchains, zio and
# the Go modules). Any failure stops it with a nonzero status.
set -eu
cd "$(dirname "$0")"
nightly=$(sed -n 's/^ARG LEAN_NIGHTLY=//p' linux/Dockerfile)
if [ "$(cat lean-toolchain)" != "leanprover/lean4:$nightly" ]; then
  echo "lean-toolchain names $(cat lean-toolchain); linux/Dockerfile installs $nightly: update the Dockerfile"; exit 1
fi
. linux/run-images.sh
image=lsrv-linux-check:$run_tag
run_image_build "$image" linux
# The run's environment, for the record.
env=$(docker run --rm --network none "$image" sh -c '
  echo "architecture: $(uname -m)"; echo "kernel: $(uname -r)"
  echo "debian: $(cat /etc/debian_version)"; echo "zig: $(zig version)"
  echo "lean: $(lean --version)"; echo "go: $(go version)"
  echo "libpq: $(pg_config --version)"; echo "postgres: $(postgres --version)"')
printf '%s\n' "$env"
echo "zio: $(sed -n 's/.*lalinsky\/zio#\([0-9a-f]*\)".*/\1/p' zig/build.zig.zon)"
# Drift fails the run (item zg4hrz). linux/Dockerfile pins the base image by
# digest and Zig by version and checksum, but takes PostgreSQL 17 from
# Debian's archive as of the build: libpq (pg_config) and the server must
# both be major 17. Zig must be on zig/build.zig.zon's minimum_zig_version
# line (same major.minor; Zig's minor releases break the language and the
# build API) and not below it.
field() { printf '%s\n' "$env" | sed -n "s/^$1: //p"; }
libpq_major=$(field libpq | sed -n 's/^PostgreSQL \([0-9][0-9]*\).*/\1/p')
server_major=$(field postgres | sed -n 's/^postgres (PostgreSQL) \([0-9][0-9]*\).*/\1/p')
if [ "$libpq_major" != 17 ] || [ "$server_major" != 17 ]; then
  echo "linux/Dockerfile installs PostgreSQL 17; the image has libpq major '$libpq_major' and server major '$server_major'"; exit 1
fi
version='[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*'
zig_min=$(sed -n "s/^[[:space:]]*\.minimum_zig_version = \"\($version\)\",[[:space:]]*\$/\1/p" zig/build.zig.zon)
if [ -z "$zig_min" ]; then
  echo "could not read minimum_zig_version (MAJOR.MINOR.PATCH) from zig/build.zig.zon"; exit 1
fi
zig_have=$(field zig | sed -n "s/^\($version\)\$/\1/p")
if [ -z "$zig_have" ]; then
  echo "the image's zig version is '$(field zig)', not MAJOR.MINOR.PATCH"; exit 1
fi
if [ "${zig_have%.*}" != "${zig_min%.*}" ] || [ "${zig_have##*.}" -lt "${zig_min##*.}" ]; then
  echo "zig/build.zig.zon's minimum_zig_version is $zig_min; the image has Zig $zig_have: move linux/Dockerfile's ZIG_VERSION and its sums, or minimum_zig_version, so both are on one line and the image is not below the minimum"; exit 1
fi
# The tree goes into the container as an archive built first
# (linux/tree-snapshot.sh), so a failure of git or tar stops the script
# instead of hiding behind the container's status. The copy has no .git, so
# the snapshot's NUL-delimited list goes in beside it as /files, which
# check.sh's bench/mdlinks reads through MDLINKS_FILES instead of
# `git ls-files` (item gjbmli).
linux/tree-snapshot.sh "$tmp/files" "$tmp/tree.tar"
for backend in epoll io_uring; do
  echo "backend: $backend (LSRV_LINUX_BACKEND, checked by serve_test.zig)"
  # The io_uring run only turns the container's seccomp filter off: docker's
  # default profile refuses io_uring_setup, so zio's loop would not start
  # (item wi7efy). Kept for this local, developer-only container, which
  # runs the repository's own code: never carry it into production or into
  # a run of untrusted code. Neither run is privileged or mounts docker's
  # socket; the only writable mount is the download cache. Networking stays
  # on: check.sh fetches zio (zig build) and the Go modules (go build);
  # PostgreSQL itself needs none.
  seccomp=
  [ "$backend" = io_uring ] && seccomp="--security-opt seccomp=unconfined"
  # $seccomp is unquoted on purpose: empty, or two fixed words.
  docker run --rm $seccomp -e LSRV_LINUX_BACKEND="$backend" -e MDLINKS_FILES=/files \
    -v lsrv-linux-cache:/home/check/.cache -v "$tmp/tree.tar:/tree.tar:ro" -v "$tmp/files:/files:ro" "$image" \
    sh -c 'mkdir src && tar --warning=no-unknown-keyword -xf /tree.tar -C src && cd src && ./check.sh'
done
