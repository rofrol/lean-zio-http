#!/bin/sh
# The correctness checks, without the load measurements; ./bench.sh runs this
# first, and its whole run is the gate for integrating a change. First checks
# the relative links and anchors of the tracked Markdown files
# (bench/mdlinks). Builds the servers and the checks; runs the Lean unit
# tests (lsrv-test), the
# PostgreSQL pool's and the transport's tests (zig build test, which need no
# database), a check that zig/ built for Linux at the Lean toolchain's glibc
# calls nothing that glibc lacks, the module boundary check (lsrv-arch), the
# parsers' comparison (lsrv-compare; lsrv-test checks the corpus lsrv-bench
# measures, and bench.sh runs lsrv-bench), the Zig/Lean
# boundary tests (bench/boundary, which start the fixture servers themselves)
# and the end-to-end checks against the Lean server, each twice: with the
# toolchain's Std.Http.Protocol.H1 behind Server.H1Adapter (lsrv, decision
# D1) and with the hand-written comparator (lsrv-hand). Then it creates a
# private PostgreSQL cluster (its own data directory and Unix socket under a
# temporary directory, no TCP listener) and runs the database tests against
# lsrv-db (bench/dbcheck, which restarts and stops that cluster). It needs
# PostgreSQL's pg_config, initdb, pg_ctl and psql (Homebrew: postgresql@18);
# pg_config's bindir goes first on PATH. On Linux the loops run on the backend
# LSRV_LINUX_BACKEND names, epoll (unless set) or io_uring (lakefile.lean,
# zig/build.zig; item wi7efy); the servers and zig build test both use it.
# Any failing test or check stops the script with a nonzero status.
set -eu
cd "$(dirname "$0")"
backend=${LSRV_LINUX_BACKEND-epoll}
case $backend in
  epoll|io_uring) ;;
  *) echo "LSRV_LINUX_BACKEND is $backend: it must be epoll or io_uring"; exit 1 ;;
esac
. bench/lib.sh
# The relative links and anchors between the tracked Markdown files (item
# g4vate): its unit tests, then the check itself; it needs only Go and git,
# or, in a copy of the tree without .git, the list of its files in
# MDLINKS_FILES (linux-check.sh).
(cd bench/mdlinks && go test ./... && go build -o mdlinks .)
bench/mdlinks/mdlinks
# The working-tree snapshot the container scripts copy (linux/tree-snapshot.sh,
# item lmbozk); it needs only git and tar.
linux/tree-snapshot-test.sh
# lake builds the Zig library (extern_lib zsrv in lakefile.lean, ZIG_OPTIMIZE
# picks its optimization) and links it into the servers.
lake build
(cd bench/check && go build -o check .)
(cd bench/boundary && go build -o boundary .)
(cd bench/dbcheck && go build -o dbcheck .)

.lake/build/bin/lsrv-test
lean_prefix=$(lean --print-prefix)
(cd zig && zig build test -Dlinux-backend="$backend" -Dlean-include="$lean_prefix/include" -Dpq-include="$(pg_config --includedir)" \
  -Dlean-lib="$lean_prefix/lib/lean" -Dpq-lib="$(pg_config --libdir)")
# libzsrv.a for Linux (issue 4n7czb): Lean links a Linux program against the
# glibc its toolchain ships (lib/glibc/), so lakefile.lean's zsrvTarget builds
# zig/ for that glibc, and the archive must reference no libc symbol it lacks.
# This machine's toolchain may ship no glibc, so the version is stated: 2.26,
# the highest GLIBC_2.* version lib/glibc/libc.so of Lean's x86_64 Linux
# release nightly-2026-11-19 defines (checked 2026-11-19); recheck it at each
# update of lean-toolchain.
lean_glibc=2.26
# The newest glibc Zig knows: its stubs define every libc symbol Zig's std may call.
newest_glibc=$(zig targets | sed -n '/^ *\.glibc = \.{/,/}/p' | sed -n 's/^ *"\([0-9.]*\)",$/\1/p' | tail -n 1)
[ -n "$newest_glibc" ] || { echo "zig targets lists no glibc version"; exit 1; }
printf 'int main(void) { return 0; }\n' >"$tmp/main.c"
# glibc_lacks GLIBC: builds zig/ for x86_64 Linux with glibc GLIBC and writes
# to $tmp/linux-GLIBC/lacks the symbols libzsrv.a references that glibc
# $lean_glibc lacks: those a link against $lean_glibc's stubs leaves undefined
# and one against $newest_glibc's does not (the Lean and libpq symbols stay
# undefined in both). Each link must fail with undefined symbols only, and
# some (zig cc lifts ld.lld's default limit of 20 errors: it lists all of them).
glibc_lacks() {
  out="$tmp/linux-$1"
  (cd zig && zig build -Dtarget="x86_64-linux-gnu.$1" -Doptimize="${ZIG_OPTIMIZE:-ReleaseSafe}" -Dlinux-backend="$backend" \
    -Dlean-include="$lean_prefix/include" -Dpq-include="$(pg_config --includedir)" --prefix "$out")
  for v in "$lean_glibc" "$newest_glibc"; do
    if zig cc -target "x86_64-linux-gnu.$v" "$tmp/main.c" -Wl,--whole-archive "$out/lib/libzsrv.a" \
        -Wl,--no-whole-archive -o "$out/a.out" >"$out/link-$v.txt" 2>&1 ||
       grep -v -e '^$' -e '^>>> ' -e '^ld\.lld: error: undefined symbol: ' "$out/link-$v.txt" | grep -q .; then
      echo "linking libzsrv.a (glibc $1) against glibc $v did not fail with undefined symbols only:"
      cat "$out/link-$v.txt"; exit 1
    fi
    sed -n 's/^ld\.lld: error: undefined symbol: //p' "$out/link-$v.txt" | sort -u >"$out/undefined-$v"
    [ -s "$out/undefined-$v" ] || { echo "linking libzsrv.a (glibc $1) against glibc $v reported no undefined symbol"; exit 1; }
  done
  comm -23 "$out/undefined-$lean_glibc" "$out/undefined-$newest_glibc" >"$out/lacks"
}
glibc_lacks "$lean_glibc"
if [ -s "$tmp/linux-$lean_glibc/lacks" ]; then
  echo "libzsrv.a for glibc $lean_glibc references symbols glibc $lean_glibc lacks:"; cat "$tmp/linux-$lean_glibc/lacks"; exit 1
fi
# The check must also fail where it should: built for Debian 13's glibc 2.41,
# where the link failed, the archive references copy_file_range and statx.
glibc_lacks 2.41
if ! grep -qx copy_file_range "$tmp/linux-2.41/lacks" || ! grep -qx statx "$tmp/linux-2.41/lacks"; then
  echo "libzsrv.a for glibc 2.41 should reference copy_file_range and statx, which glibc $lean_glibc lacks; it references:"
  cat "$tmp/linux-2.41/lacks"; exit 1
fi
.lake/build/bin/lsrv-arch
# The check must also fail where it should: on a fixture package with an
# application importing the transport and an application no rule names,
# beside one that keeps its rule. It reports exactly those two.
arch="$tmp/arch"
mkdir -p "$arch/App"
printf 'import Server.Handler\nimport App.Hello\n' >"$arch/App/Db.lean"
printf 'import Server.Handler\nimport Server.Transport\n' >"$arch/App/Hello.lean"
printf 'import Server.Handler\n' >"$arch/App/Rogue.lean"
status=0
.lake/build/bin/lsrv-arch "$arch" >"$tmp/arch.txt" || status=$?
expected="FAIL App.Hello imports Server.Transport
FAIL App.Rogue ($arch/App/Rogue.lean): no boundary rule names this module
3 modules, 2 violations"
if [ "$status" != 1 ] || [ "$(cat "$tmp/arch.txt")" != "$expected" ]; then
  echo "lsrv-arch on its fixture exited $status, printing:"; cat "$tmp/arch.txt"; exit 1
fi
.lake/build/bin/lsrv-compare >"$tmp/compare.txt" || { cat "$tmp/compare.txt"; exit 1; }
sed -n '1,/^## Malformed/p' "$tmp/compare.txt"
grep -E '^[0-9]+ requests: [0-9]+ verdicts' "$tmp/compare.txt"
# The boundary suite opens thousands of loopback connections, and each closed
# one stays in TIME_WAIT for 2*MSL (30 s on macOS) on the side that closed it
# first, both sides being on this machine. A run
# started soon after another connection-heavy one can find the ephemeral
# ports exhausted and fail a dial with EADDRNOTAVAIL, which the suite then
# names (item vyzkxi). Where sysctl has them (macOS), the kernel's TCP PCB
# count, which counts every TCP socket of the system and not only the
# ephemeral ports in use, and the ephemeral port range are printed before the
# suite's two runs and again when one fails. Only diagnostics: no wait, no
# retry. tcp_ports WHEN prints them, labeled WHEN.
tcp_ports() {
  v=$(sysctl -n net.inet.tcp.pcbcount net.inet.ip.portrange.first net.inet.ip.portrange.last 2>/dev/null) || return 0
  when=$1
  set -- $v
  [ $# -eq 3 ] || return 0
  echo "$when: TCP PCBs in the kernel (every socket, system-wide): $1; ephemeral ports $2-$3"
}
tcp_ports "before the boundary suite (lsrv-fixture)"
bench/boundary/boundary || { tcp_ports "after the boundary suite failed (lsrv-fixture)"; exit 1; }
tcp_ports "before the boundary suite (lsrv-fixture-hand)"
bench/boundary/boundary -no-continue -fixture .lake/build/bin/lsrv-fixture-hand ||
  { tcp_ports "after the boundary suite failed (lsrv-fixture-hand)"; exit 1; }
# A port another process holds (here a running lsrv's): a server asked for it
# must say why, with the errno, and exit 1 before "ready"; a server on a port
# the kernel picks starts beside it and passes the end-to-end checks.
start holder ready .lake/build/bin/lsrv 1 --port 0
held=$addr; holder=$pid
# Its stderr goes through a fifo, so a server that gets the port anyway is
# seen at its "ready" and stopped instead of serving forever. A last line
# without a newline is kept too, so it counts as a second line. A server
# that hangs instead keeps the check quiet, which its runner reports.
mkfifo "$tmp/taken"
.lake/build/bin/lsrv 1 --port "${held##*:}" >"$tmp/taken.out" 2>"$tmp/taken" &
taken_pid=$!
pids="$pids $taken_pid"
: >"$tmp/taken.err"
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line" >>"$tmp/taken.err"
  if [ "$line" = ready ]; then kill -TERM "$taken_pid"; fi
done <"$tmp/taken"
status=0
wait "$taken_pid" || status=$?
if [ "$status" != 1 ] || [ -s "$tmp/taken.out" ] || [ "$(wc -l <"$tmp/taken.err")" -ne 1 ] ||
   ! grep -Eqx "cannot bind $(printf '%s' "$held" | sed 's/\./\\./g'): errno [0-9]+ \(ADDRINUSE\)" "$tmp/taken.err"; then
  echo "lsrv on the taken $held exited $status; stdout:"; cat "$tmp/taken.out"; echo "stderr:"; cat "$tmp/taken.err"; exit 1
fi
start lean-h1 ready .lake/build/bin/lsrv 8 --port 0
[ "$addr" != "$held" ] || { echo "lean-h1 got $addr, which holder holds"; exit 1; }
bench/check/check -addr "$addr"
stop graceful
pid=$holder; name=holder
stop graceful

start lean-hand ready .lake/build/bin/lsrv-hand 8 --port 0
bench/check/check -addr "$addr"
stop graceful

pg_start
bench/dbcheck/dbcheck -pg "$pg" -pgdata "$pgdata" -pgopts "$pgopts" -pglog "$tmp/pg.log" -world42 "$world42"
