#!/bin/sh
# bench/arena/build.sh OUT ARENA: builds, on this machine, everything the
# HttpArena runs on the VPS need, for x86_64 Linux, into OUT (a new, empty
# directory), from ARENA, a checkout of https://github.com/MDA2AV/HttpArena at
# the commit below (item 53rwgc; README, "HttpArena on the VPS"). Nothing is
# built on the VPS: its disk is shared and nearly full.
#
# - lsrv-arena (MainArena.lean) and the transport's and the pool's test
#   binaries (`zig build test` in zig/: pg_test, serve_test, pg_glue_test),
#   once per Linux backend (epoll, io_uring), in linux/Dockerfile's image for
#   linux/amd64 (Zig cross-compiling from aarch64, below). The test binaries
#   run only on the VPS (bench/arena/run.sh tests).
# - For bench/dbpairs.sh on the VPS (run.sh db; item akj76n): lsrv-db (epoll),
#   bench/load and bench/pgserver, laid out under OUT/db as the repository
#   lays them out.
# - gcannon (HttpArena's load generator, io_uring) at a pinned commit, with
#   liburing 2.9 as docker/gcannon.Dockerfile builds it; at that commit it
#   also needs OpenSSL's headers (src/ktls.c), which that Dockerfile lacks;
#   with gcannon-served.patch (its "Connections served" line).
# - zrk 2.3.0 (the fixed-rate generator of the latency profiles), checked
#   against the SHA-256 that docker/zrk.Dockerfile pins.
# - HttpArena's go-stdlib and go-fasthttp entries, cross-compiled with this
#   machine's Go as their Dockerfiles build them (CGO_ENABLED=0, -trimpath,
#   -s -w).
# Needs docker (on the M1, OrbStack with Rosetta for linux/amd64), Go and
# network access.
set -eu
arena_commit=da3ded60952b90e5a70f970cec3eae15009d302b
gcannon_commit=fb63bf61387314aaaafe6b1fd890b2efc72f8c33
liburing_commit=31a41935866867cdfedb4ef5a57ce0d15b50e5b9 # tag liburing-2.9
zrk_version=2.3.0
zrk_sha256=ab6f1c1ce34ce73f52afd106419d15e5c494bd1cedd475afa56babb85b09a816
[ $# -eq 2 ] || { echo "usage: $0 OUT ARENA"; exit 2; }
out=$1 arena=$2
[ -d "$out" ] && [ -z "$(ls -A "$out")" ] || { echo "$out must be an empty directory"; exit 2; }
out=$(cd "$out" && pwd) arena=$(cd "$arena" && pwd)
[ "$(git -C "$arena" rev-parse HEAD)" = "$arena_commit" ] || { echo "$arena is not at $arena_commit"; exit 1; }
cd "$(dirname "$0")/../.."
mkdir "$out/lib" "$out/requests"
# db/ mirrors the repository paths bench/dbpairs.sh runs from (run.sh db).
mkdir -p "$out/db/.lake/build/bin" "$out/db/bench/load" "$out/db/bench/pgserver"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
git ls-files -z --cached --others --exclude-standard >"$tmp/files"
COPYFILE_DISABLE=1 tar --null -T "$tmp/files" -cf "$tmp/tree.tar"
image=lsrv-linux-check-amd64
docker build -q --platform linux/amd64 -t "$image" linux >/dev/null
# seccomp off: docker's default profile refuses io_uring_setup (linux-check.sh).
zig_version=$(sed -n 's/^ARG ZIG_VERSION=//p' linux/Dockerfile)
zig_sum=$(sed -n 's/^ARG ZIG_SHA256_AARCH64=//p' linux/Dockerfile)
docker run --rm --platform linux/amd64 --security-opt seccomp=unconfined \
  -e ZIG_VERSION="$zig_version" -e ZIG_SHA256_AARCH64="$zig_sum" \
  -v lsrv-linux-cache-amd64:/home/check/.cache -v "$tmp/tree.tar:/tree.tar:ro" -v "$out:/out" "$image" sh -c '
  set -eu
  # The image'"'"'s x86_64 Zig stops under Rosetta ("rosetta error: bss_size
  # overflow", 2026-11-17, OrbStack on the M1), while x86_64 Lean and clang run.
  # So Zig is the same release built for aarch64, which the arm64 kernel runs
  # without Rosetta (it is static), cross-compiling for x86_64: the "zig" first
  # on PATH turns lakefile.lean'"'"'s -Dtarget=native-linux-gnu.V into
  # x86_64-linux-gnu.V and passes everything else on unchanged.
  mkdir -p /tmp/zig-arm /tmp/bin && cd /tmp
  curl -fsSLo zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-linux-$ZIG_VERSION.tar.xz"
  echo "$ZIG_SHA256_AARCH64  zig.tar.xz" | sha256sum -c - >/dev/null
  tar -xJf zig.tar.xz -C /tmp/zig-arm --strip-components=1 && rm zig.tar.xz
  printf "%s\n" "#!/bin/sh" "for a do shift; case \$a in -Dtarget=native-*) a=-Dtarget=x86_64-\${a#-Dtarget=native-} ;; esac; set -- \"\$@\" \"\$a\"; done" "exec /tmp/zig-arm/zig \"\$@\"" >/tmp/bin/zig
  chmod +x /tmp/bin/zig
  export PATH=/tmp/bin:$PATH
  cd && mkdir src && tar --warning=no-unknown-keyword -xf /tree.tar -C src && cd src
  . bench/lib.sh
  export LIBRARY_PATH=$(pg_config --libdir)
  lean_prefix=$(lean --print-prefix)
  for backend in epoll io_uring; do
    LSRV_LINUX_BACKEND=$backend lake build lsrv-arena
    cp .lake/build/bin/lsrv-arena /out/lsrv-arena-$backend
    # lsrv-db for bench/dbpairs.sh (run.sh db), on the build'"'"'s default backend.
    if [ $backend = epoll ]; then
      LSRV_LINUX_BACKEND=$backend lake build lsrv-db
      cp .lake/build/bin/lsrv-db /out/db/.lake/build/bin/lsrv-db
    fi
    touch /tmp/mark
    # Built for the VPS'"'"'s glibc (Debian 13: 2.41). Zig also runs them here,
    # under Rosetta, where io_uring_setup and other calls fail with ENOSYS
    # (2026-11-17): that run says nothing about Linux, so its status is
    # ignored; the binaries must exist (checked below), and
    # bench/arena/run.sh tests runs them on the VPS.
    (cd zig && zig build test -Dtarget=x86_64-linux-gnu.2.41 -Dlinux-backend=$backend -Dlean-include="$lean_prefix/include" -Dpq-include="$(pg_config --includedir)" \
      -Dlean-lib="$lean_prefix/lib/lean" -Dpq-lib="$(pg_config --libdir)") || true
    # zig build test names both test binaries "test"; serve_test is the one
    # with the backend test in it. pg_glue_test runs no event loop, so it is
    # built once, for both backends.
    for f in $(find zig/.zig-cache/o -type f \( -name test -o -name pg_glue_test \) -newer /tmp/mark); do
      case $f in
        */pg_glue_test) cp "$f" /out/pg_glue_test ;;
        *) if grep -q "the loops run on the backend" "$f"; then cp "$f" /out/serve_test-$backend; else cp "$f" /out/pg_test-$backend; fi ;;
      esac
    done
  done
  cp "$lean_prefix/lib/lean/libleanshared.so" /out/lib/
  { echo "lean: $(lean --version)"; echo "zig: $(zig version)"; echo "libpq (build): $(pg_config --version)"
    echo "zio: $(sed -n "s/.*lalinsky\/zio#\([0-9a-f]*\)\".*/\1/p" zig/build.zig.zon)"; } >/out/versions.txt'
for b in epoll io_uring; do
  for f in lsrv-arena serve_test pg_test; do
    [ -x "$out/$f-$b" ] || { echo "missing $f-$b"; exit 1; }
  done
done
[ -x "$out/pg_glue_test" ] || { echo "missing pg_glue_test"; exit 1; }
[ -x "$out/db/.lake/build/bin/lsrv-db" ] || { echo "missing lsrv-db"; exit 1; }

# bench/dbpairs.sh's load generator and Go server, as its header says to
# build them, for x86_64 Linux.
for p in load pgserver; do
  case $p in load) bin=load ;; pgserver) bin=server ;; esac
  (cd bench/$p && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "$out/db/bench/$p/$bin" .)
done
cp bench/dbpairs.sh "$out/db/bench/"
cp bench/lib.sh "$out/db/bench/"

# gcannon.Dockerfile builds from linux/Dockerfile's debian:trixie digest.
docker build -q --platform linux/amd64 --build-arg LIBURING_COMMIT="$liburing_commit" \
  --build-arg GCANNON_COMMIT="$gcannon_commit" --output "type=local,dest=$tmp/gcannon" \
  -f bench/arena/gcannon.Dockerfile bench/arena >/dev/null
cp "$tmp/gcannon/gcannon" "$out/gcannon"
cp -P "$tmp"/gcannon/lib/liburing.so.2.9 "$tmp"/gcannon/lib/liburing.so.2 "$out/lib/"

curl -fsSLo "$tmp/zrk.tar.gz" "https://github.com/zoxy-io/zrk/releases/download/v$zrk_version/zrk-$zrk_version-x86_64-linux.tar.gz"
echo "$zrk_sha256  $tmp/zrk.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$tmp/zrk.tar.gz" -C "$tmp" zrk && cp "$tmp/zrk" "$out/zrk"

for entry in go-stdlib go-fasthttp; do
  (cd "$arena/frameworks/$entry" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o "$out/$entry" main.go)
done
cp "$arena"/requests/get.raw "$arena"/requests/post_cl.raw "$arena"/requests/post_chunked.raw "$arena"/requests/pipeline.raw "$out/requests/"
cp bench/arena/run.sh bench/arena/inner.sh "$out/"
{ echo "httparena: $arena_commit"; echo "gcannon: $gcannon_commit (liburing 2.9, $liburing_commit)"
  echo "zrk: $zrk_version"; echo "go (go entries): $(go version)"; echo "lsrv: $(git rev-parse HEAD)$(git diff --quiet HEAD || echo ' with uncommitted changes')"; } >>"$out/versions.txt"
du -sh "$out"
