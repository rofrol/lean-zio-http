#!/bin/sh
# Every item's integration gate: runs ./check.sh (the builds, tests and
# correctness checks, which also runs on its own while editing), then the
# load measurements. It measures each server: requests per second, latency,
# and server CPU time per request at 1, 64 and 256 keep-alive connections,
# 10 s per run, all on this machine. Then it creates a fresh private
# PostgreSQL cluster (bench/lib.sh, pg_start) and measures lsrv-db against
# Go with pgx (bench/pgserver) on GET /db?id=42 at 1 and 64 connections,
# printing lean's throughput as a share of Go's.
# Any failing test, check or load run stops the script with a nonzero status.
set -eu
cd "$(dirname "$0")"
./check.sh
. bench/lib.sh
(cd dusty-hello && zig build -Doptimize=ReleaseFast)
(cd bench/load && go build -o load .)
(cd bench/goserver && go build -o server .)
(cd bench/pgserver && go build -o server .)

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

start lean-h1 ready .lake/build/bin/lsrv 8
measure lean-h1 8083
stop graceful

start lean-hand ready .lake/build/bin/lsrv-hand 8
measure lean-hand 8083
stop graceful

start go ready bench/goserver/server
measure go 8082
stop

start dusty "Listening on" dusty-hello/zig-out/bin/dhello
measure dusty 8084
stop

pg_start

# measure_db NAME PORT: GET /db?id=42 at 1 and 64 connections; sets rps_1 and
# rps_64 to the requests per second.
measure_db() {
  name=$1; port=$2
  for c in 1 64; do
    before=$(cpu "$pid")
    result=$(bench/load/load -url "http://127.0.0.1:$port/db?id=42" -c "$c" -d 10s -body '{"id":42,"randomNumber":2599}') || { echo "$name c=$c $result"; exit 1; }
    after=$(cpu "$pid")
    n=$(echo "$result" | sed -E 's/.* n=([0-9]+).*/\1/')
    echo "$name c=$c $result cpu_us_per_req=$(echo "($after - $before) * 1000000 / $n" | bc)"
    eval "rps_$c=$(echo "$result" | sed -E 's/^req\/s=([0-9]+).*/\1/')"
  done
}
# 8 loops with 4 connections each against one pool of 32.
start lean-db ready .lake/build/bin/lsrv-db 8 --pg "$pg" --pg-conns 4
measure_db lean-db 8083
stop graceful
lean_1=$rps_1; lean_64=$rps_64
start go-db ready bench/pgserver/server -pg "$pg" -conns 32
measure_db go-db 8082
stop
echo "lean-db/go-db c=1 $(echo "scale=2; $lean_1 / $rps_1" | bc) c=64 $(echo "scale=2; $lean_64 / $rps_64" | bc) (goal: at least 0.9)"
