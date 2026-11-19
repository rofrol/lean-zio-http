#!/bin/sh
# bench/dbpairs.sh [-n REQUESTS] [-r ROUNDS] [-g GOMAXPROCS]: measures lsrv-db against Go
# with pgx (bench/pgserver) at one connection on GET /db?id=42 in paired
# samples (item 7wvkwz). Linux only (it reads /proc); opt-in, not part of
# check.sh or bench.sh. Run it from the repository root after `lake build`
# and `go build -o load .` in bench/load and `go build -o server .` in
# bench/pgserver. In the Linux container, build and run it as
# docs/running.md shows for bench.sh; docs/reports/postgresql-throughput.md
# has its findings.
#
# It creates a private cluster (bench/lib.sh, pg_start), starts both servers
# once with bench.sh's settings, warms each with REQUESTS requests (not
# printed), then runs ROUNDS (default 10) pairs. Each pair runs both servers
# one after the other, lean-db first in odd rounds and go-db first in even
# ones, each sample ending after the same REQUESTS (default 100000) completed
# requests (bench/load -n). Per sample it prints requests per second and
# latency, the server's CPU time per request, its voluntary and involuntary
# context switches per request (summed over its threads) and the CPU time
# per request of the private cluster's processes (the postmaster and its
# children). Each sum takes every thread or process (by ID and start time)
# present after the sample, less what it had before; one that started during
# the sample (a backend that a new loop's first query connects, say) counts
# whole. One that ended during the sample takes its counts with it:
# `exited=1` marks such a sample; one that started and ended between the
# snapshots is not seen at all. The snapshots bracket the whole bench/load
# run, so its one warm-up request (and any session that opens) is in the
# sums, divided by REQUESTS like the rest. Per pair it prints lean-db's requests per second
# divided by go-db's. -g runs go-db with that GOMAXPROCS (default:
# Go's own, the number of CPUs), to compare a Go runtime with no idle
# processor to spin on. Measurements are comparative and depend on the
# machine; they decide nothing on their own.
set -eu
requests=100000
rounds=10
gomaxprocs=
while getopts n:r:g: o; do
  case $o in
    n) requests=$OPTARG ;;
    r) rounds=$OPTARG ;;
    g) gomaxprocs=$OPTARG ;;
    *) echo "usage: $0 [-n REQUESTS] [-r ROUNDS] [-g GOMAXPROCS]" >&2; exit 2 ;;
  esac
done
for v in "$requests" "$rounds"; do
  case $v in ''|*[!0-9]*|0) echo "-n and -r take a positive integer, not '$v'" >&2; exit 2 ;; esac
done
[ -d /proc/self/task ] || { echo "$0 reads /proc: run it on Linux" >&2; exit 2; }
for f in .lake/build/bin/lsrv-db bench/load/load bench/pgserver/server; do
  [ -x "$f" ] || { echo "$f is missing (see the header)" >&2; exit 2; }
done
. bench/lib.sh

# fields STAT: the fields of a /proc stat line after the command name, which
# may hold spaces: $1 is the state, $2 the parent, $12 utime, $13 stime, $20
# the start time.
fields() { printf '%s\n' "${1##*) }"; }
# snap PID: one line per thread of PID, "s TID:START CPU_TICKS VOLUNTARY
# INVOLUNTARY", and per process of the private cluster, "p PID:START
# CPU_TICKS".
# A thread or process that ends while it is read is left out.
snap() {
  for t in /proc/"$1"/task/[0-9]*; do
    { st=$(cat "$t/stat") && ss=$(cat "$t/status"); } 2>/dev/null || continue
    echo "s ${t##*/}:$(fields "$st" | awk '{ print $20, $12 + $13 }') $(printf '%s\n' "$ss" |
      awk '/^voluntary_ctxt_switches/ { v = $2 } /^nonvoluntary_ctxt_switches/ { n = $2 } END { print v, n }')"
  done
  pm=$(head -1 "$pgdata/postmaster.pid")
  for d in /proc/[0-9]*; do
    st=$(cat "$d/stat" 2>/dev/null) || continue
    f=$(fields "$st")
    case "${d##*/} $(echo "$f" | awk '{ print $2 }')" in
      "$pm "*|*" $pm") echo "p ${d##*/}:$(echo "$f" | awk '{ print $20, $12 + $13 }')" ;;
    esac
  done
}

pg_start
start lean-db ready .lake/build/bin/lsrv-db 8 --port 0 --pg "$pg" --pg-conns 4
lean_pid=$pid lean_addr=$addr
start go-db ready env ${gomaxprocs:+GOMAXPROCS=$gomaxprocs} bench/pgserver/server -pg "$pg" -conns 32
go_pid=$pid go_addr=$addr

# sample NAME PID ADDR: one run of REQUESTS requests; sets rps.
sample() {
  snap "$2" >"$tmp/before"
  result=$(bench/load/load -url "http://$3/db?id=42" -c 1 -n "$requests" -body '{"id":42,"randomNumber":2599}') ||
    { echo "$1 $result" >&2; exit 1; }
  snap "$2" >"$tmp/after"
  rps=$(echo "$result" | sed -n -E 's/^req\/s=([0-9]+) .*/\1/p')
  [ -n "$rps" ] && [ "$rps" -gt 0 ] || { echo "$1: no requests per second in '$result'" >&2; exit 1; }
  line=$(awk -v n="$requests" -v hz="$(getconf CLK_TCK)" -v name="$1" -v res="$result" '
    FNR == NR { b[$1 " " $2] = $0; next }
    { k = $1 " " $2; seen[k] = 1
      split("0 0 0 0 0", x, " "); if (k in b) split(b[k], x, " ")
      if ($1 == "s") { cpu += $3 - x[3]; v += $4 - x[4]; iv += $5 - x[5] } else pg += $3 - x[3] }
    END {
      for (k in b) if (!(k in seen)) exited = 1
      printf "%s c=1 %s cpu_us_per_req=%.1f vcsw_per_req=%.2f ivcsw_per_req=%.3f pg_cpu_us_per_req=%.1f%s\n",
        name, res, cpu / hz * 1e6 / n, v / n, iv / n, pg / hz * 1e6 / n, exited ? " exited=1" : "" }' \
    "$tmp/before" "$tmp/after")
  echo "$line"
}

sample warm-lean-db "$lean_pid" "$lean_addr" >/dev/null
sample warm-go-db "$go_pid" "$go_addr" >/dev/null
round=1
while [ "$round" -le "$rounds" ]; do
  if [ $((round % 2)) = 1 ]; then
    printf 'round=%s ' "$round"; sample lean-db "$lean_pid" "$lean_addr"; lean_rps=$rps
    printf 'round=%s ' "$round"; sample go-db "$go_pid" "$go_addr"; go_rps=$rps
  else
    printf 'round=%s ' "$round"; sample go-db "$go_pid" "$go_addr"; go_rps=$rps
    printf 'round=%s ' "$round"; sample lean-db "$lean_pid" "$lean_addr"; lean_rps=$rps
  fi
  # awk, not bc: the VPS (bench/arena/run.sh db) has no bc.
  ratio=$(awk -v l="$lean_rps" -v g="$go_rps" 'BEGIN { printf "%.2f", l / g }')
  echo "round=$round lean-db/go-db $ratio"
  round=$((round + 1))
done
pid=$lean_pid name=lean-db
stop graceful
pid=$go_pid name=go-db
stop
