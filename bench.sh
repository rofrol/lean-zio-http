#!/bin/sh
# Every item's integration gate: runs ./check.sh (the builds, tests and
# correctness checks, which also runs on its own while editing), then the
# measurements. lsrv-bench measures both parsers' cost per request and per
# fragmented request, without sockets (one line per measured case). Then it
# measures each server: requests per second, latency,
# and server CPU time per request at 1, 64 and 256 keep-alive connections,
# 10 s per run, all on this machine. Then it creates a fresh private
# PostgreSQL cluster (bench/lib.sh, pg_start) and measures lsrv-db against
# Go with pgx (bench/pgserver) on GET /db?id=42 at 1 and 64 connections,
# printing lean's throughput as a share of Go's.
# Any failing test, check or load run stops the script with a nonzero status.
set -eu
cd "$(dirname "$0")"
# The CPU per request and lean's share of Go are computed with bc; without
# it they would print empty, so stop before the long run instead.
command -v bc >/dev/null || { echo "bench.sh needs bc (CPU per request, lean-db/go-db): install it"; exit 1; }
./check.sh
. bench/lib.sh
# Built by check.sh's lake build.
.lake/build/bin/lsrv-bench
(cd dusty-hello && zig build -Doptimize=ReleaseFast)
(cd bench/load && go build -o load .)
(cd bench/goserver && go build -o server .)
(cd bench/pgserver && go build -o server .)

# measure NAME: the server `start` started last, at $addr.
measure() {
  name=$1
  for c in 1 64 256; do
    before=$(cpu "$pid")
    result=$(bench/load/load -url "http://$addr/" -c "$c" -d 10s) || { echo "$name c=$c $result"; exit 1; }
    after=$(cpu "$pid")
    n=$(echo "$result" | sed -E 's/.* n=([0-9]+).*/\1/')
    echo "$name c=$c $result cpu_us_per_req=$(echo "($after - $before) * 1000000 / $n" | bc)"
  done
}

start lean-h1 ready .lake/build/bin/lsrv 8 --port 0
measure lean-h1
stop graceful

start lean-hand ready .lake/build/bin/lsrv-hand 8 --port 0
measure lean-hand
stop graceful

start go ready bench/goserver/server
measure go
stop

start dusty "Listening on" dusty-hello/zig-out/bin/dhello
measure dusty
stop

pg_start

# measure_db NAME: GET /db?id=42 at 1 and 64 connections on the server
# `start` started last, at $addr; sets rps_1 and rps_64 to the requests per
# second.
measure_db() {
  name=$1
  for c in 1 64; do
    before=$(cpu "$pid")
    result=$(bench/load/load -url "http://$addr/db?id=42" -c "$c" -d 10s -body "$world42") || { echo "$name c=$c $result"; exit 1; }
    after=$(cpu "$pid")
    n=$(echo "$result" | sed -E 's/.* n=([0-9]+).*/\1/')
    echo "$name c=$c $result cpu_us_per_req=$(echo "($after - $before) * 1000000 / $n" | bc)"
    eval "rps_$c=$(echo "$result" | sed -E 's/^req\/s=([0-9]+).*/\1/')"
  done
}
# 8 loops with 4 connections each against one pool of 32.
start lean-db ready .lake/build/bin/lsrv-db 8 --port 0 --pg "$pg" --pg-conns 4
measure_db lean-db
stop graceful
lean_1=$rps_1; lean_64=$rps_64
start go-db ready bench/pgserver/server -pg "$pg" -conns 32
measure_db go-db
stop
echo "lean-db/go-db c=1 $(echo "scale=2; $lean_1 / $rps_1" | bc) c=64 $(echo "scale=2; $lean_64 / $rps_64" | bc) (goal: at least 0.9)"
