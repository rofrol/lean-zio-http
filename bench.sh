#!/bin/sh
# Builds the three servers, the checks and the load generator; runs the Lean
# unit tests and the end-to-end checks against the Lean server; then measures
# each server: requests per second, latency, and server CPU time per request
# at 1, 64 and 256 keep-alive connections, 10 s per run, all on this machine.
# Any failing test, check or load run stops the script with a nonzero status.
set -eu
cd "$(dirname "$0")"
# The include directory of the toolchain lean/lean-toolchain pins.
LEAN_INCLUDE="$(cd lean && lean --print-prefix)/include"
(cd zig && zig build -Drelease=true -Dlean-include="$LEAN_INCLUDE")
# Lake does not track libzsrv.a (passed through moreLinkArgs), so drop the
# executable to make it link against the library just built.
rm -f lean/.lake/build/bin/lsrv
(cd lean && lake build)
(cd dusty-hello && zig build -Doptimize=ReleaseFast)
(cd bench/load && go build -o load .)
(cd bench/check && go build -o check .)
(cd bench/goserver && go build -o server .)

tmp=$(mktemp -d)
pids=""
cleanup() {
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# Server CPU time (user + system) in seconds: /proc on Linux, ps on macOS,
# whose TIME column is [[dd-]hh:]mm:ss.ss.
cpu() {
  if [ -r "/proc/$1/stat" ]; then
    awk -v hz="$(getconf CLK_TCK)" '{print ($14 + $15) / hz}' "/proc/$1/stat"
  else
    ps -o time= -p "$1" | awk '{
      t = $1; d = 0
      if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, p, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + p[i]
      print d * 86400 + s }'
  fi
}

# start NAME READY-TEXT COMMAND...: starts a server and returns once it has
# printed a line containing READY-TEXT (or fails if its output ends first,
# which means it exited). Sets $pid.
start() {
  name=$1; ready=$2; shift 2
  mkfifo "$tmp/$name"
  "$@" >"$tmp/$name" 2>&1 &
  pid=$!
  pids="$pids $pid"
  exec 3<"$tmp/$name"
  up=no
  while IFS= read -r line <&3; do
    case $line in *"$ready"*) up=yes; break ;; esac
  done
  if [ "$up" != yes ]; then echo "$name exited before it listened"; exit 1; fi
  cat <&3 >/dev/null &   # keep draining its output
  pids="$pids $!"
  exec 3<&-
}

stop() { kill -TERM "$pid"; wait "$pid" 2>/dev/null || true; }

measure() {
  name=$1; port=$2
  for c in 1 64 256; do
    before=$(cpu "$pid")
    result=$(bench/load/load -url "http://127.0.0.1:$port/" -c "$c" -d 10s) || { echo "$name c=$c $result"; exit 1; }
    after=$(cpu "$pid")
    n=$(echo "$result" | sed -E 's/.* n=([0-9]+).*/\1/')
    echo "$name c=$c $result cpu_us_per_req=$(echo "($after - $before) * 1000000 / $n" | bc)"
  done
}

lean/.lake/build/bin/lsrv-test
start lean-zio ready lean/.lake/build/bin/lsrv 8
bench/check/check -addr 127.0.0.1:8083
measure lean-zio 8083
stop

start go ready bench/goserver/server
measure go 8082
stop

start dusty "Listening on" dusty-hello/zig-out/bin/dhello
measure dusty 8084
stop
