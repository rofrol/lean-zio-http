#!/bin/sh
# Builds the servers, the checks and the load generator; runs the Lean unit
# tests (lsrv-test), the module boundary check (lsrv-arch), the Zig/Lean
# boundary tests (bench/boundary, which start the fixture servers themselves)
# and the end-to-end checks against the Lean server, each twice: with the
# toolchain's Std.Http.Protocol.H1 behind Server.H1Adapter (lsrv, decision
# D1) and with the hand-written comparator (lsrv-hand); compares the two
# parsers' verdicts (lsrv-compare), their cost per request and on fragmented
# requests (lsrv-bench); then measures
# each server: requests per second, latency, and server CPU time per request
# at 1, 64 and 256 keep-alive connections, 10 s per run, all on this machine.
# Then it creates a private PostgreSQL cluster (its own data directory and
# Unix socket under a temporary directory, no TCP listener), runs the
# database tests against lsrv-db (bench/dbcheck, which restarts and stops
# that cluster) and measures lsrv-db against Go with pgx (bench/pgserver) on
# GET /db?id=42 at 1 and 64 connections, printing lean's throughput as a
# share of Go's. It needs PostgreSQL's pg_config, initdb, pg_ctl and psql
# (Homebrew: postgresql@18); pg_config's bindir goes first on PATH.
# Any failing test, check or load run stops the script with a nonzero status.
set -eu
cd "$(dirname "$0")"
PATH="$(pg_config --bindir):$PATH"
# lake links the servers with -lpq from pg_config's libdir.
LIBRARY_PATH="$(pg_config --libdir)${LIBRARY_PATH:+:$LIBRARY_PATH}"
export PATH LIBRARY_PATH
# lake builds the Zig library (extern_lib zsrv in lakefile.lean, ZIG_OPTIMIZE
# picks its optimization) and links it into the servers.
lake build
(cd dusty-hello && zig build -Doptimize=ReleaseFast)
(cd bench/load && go build -o load .)
(cd bench/check && go build -o check .)
(cd bench/boundary && go build -o boundary .)
(cd bench/goserver && go build -o server .)
(cd bench/pgserver && go build -o server .)
(cd bench/dbcheck && go build -o dbcheck .)

tmp=$(mktemp -d)
pids=""
pgdata=""
cleanup() {
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  if [ -n "$pgdata" ]; then pg_ctl -D "$pgdata" -m immediate stop >/dev/null 2>&1 || true; fi
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

# stop [graceful]: SIGTERM; with `graceful`, the server must exit with status
# 0 (the Lean servers' shutdown, README "Production contract").
stop() {
  kill -TERM "$pid"
  status=0
  wait "$pid" 2>/dev/null || status=$?
  if [ "${1:-}" = graceful ] && [ "$status" != 0 ]; then echo "$name exited with $status after SIGTERM"; exit 1; fi
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

.lake/build/bin/lsrv-test
.lake/build/bin/lsrv-arch
.lake/build/bin/lsrv-compare >"$tmp/compare.txt" || { cat "$tmp/compare.txt"; exit 1; }
sed -n '1,/^## Malformed/p' "$tmp/compare.txt"
grep -E '^[0-9]+ requests: [0-9]+ verdicts' "$tmp/compare.txt"
.lake/build/bin/lsrv-bench
bench/boundary/boundary
bench/boundary/boundary -no-continue -fixture .lake/build/bin/lsrv-fixture-hand
start lean-h1 ready .lake/build/bin/lsrv 8
bench/check/check -addr 127.0.0.1:8083
measure lean-h1 8083
stop graceful

start lean-hand ready .lake/build/bin/lsrv-hand 8
bench/check/check -addr 127.0.0.1:8083
measure lean-hand 8083
stop graceful

start go ready bench/goserver/server
measure go 8082
stop

start dusty "Listening on" dusty-hello/zig-out/bin/dhello
measure dusty 8084
stop

# The private cluster: trust authentication on its own Unix socket only.
pgdata="$tmp/pgdata"
pgopts="-c listen_addresses= -c unix_socket_directories=$tmp -p 5499 -c max_prepared_transactions=4 -c max_connections=200"
pg="host=$tmp port=5499 user=postgres dbname=postgres"
initdb -D "$pgdata" -U postgres --auth=trust -E UTF8 --no-locale >"$tmp/initdb.log" 2>&1 || { cat "$tmp/initdb.log"; exit 1; }
pg_ctl -D "$pgdata" -w -l "$tmp/pg.log" -o "$pgopts" start >/dev/null
# The rows of world: randomnumber = (id * 7919) mod 10000 + 1 (42 -> 2599).
psql "$pg" -q -v ON_ERROR_STOP=1 -c "CREATE TABLE world (id int PRIMARY KEY, randomnumber int NOT NULL);
  INSERT INTO world SELECT i, (i * 7919) % 10000 + 1 FROM generate_series(1, 10000) i; ANALYZE world;"
bench/dbcheck/dbcheck -pg "$pg" -pgdata "$pgdata" -pgopts "$pgopts" -pglog "$tmp/pg.log"

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
