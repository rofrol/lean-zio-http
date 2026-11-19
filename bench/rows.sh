#!/bin/sh
# bench/rows.sh [-d DURATION] [-r ROUNDS] [-k CASES] NAME=SERVER...: measures what
# collecting many rows costs, comparing builds of lsrv-db (item 4lmjda, which
# compared libpq's single-row mode with its chunked-rows mode). Opt-in, not
# part of check.sh or bench.sh; run it from the repository root after
# `lake build` (lsrv-db) and `go build -o load .` in bench/load.
#
# It creates a private cluster (bench/lib.sh, pg_start) and, for each round,
# each case and each SERVER in turn, starts a fresh SERVER (8 loops with 4
# connections each, as bench.sh), runs GET /rows?n=N&len=L (App/Db.lean) for
# DURATION (default 8s) at C connections and prints one line: requests per
# second, latency, server CPU time per request, and the process's peak
# resident set size over its whole run (/usr/bin/time: bytes on macOS,
# kilobytes on Linux, as printed). A fresh process per case keeps one case's
# peak from hiding another's. Measurements are comparative and depend on the
# machine; they decide nothing on their own.
set -eu
duration=8s
rounds=2
# The cases, N:L:C each: N rows of L bytes at C connections.
cases="1:100:1 100:100:1 1000:100:1 1000:100:64 900:1000:64"
while getopts d:r:k: o; do
  case $o in
    d) duration=$OPTARG ;;
    r) rounds=$OPTARG ;;
    k) cases=$OPTARG ;;
    *) echo "usage: $0 [-d DURATION] [-r ROUNDS] [-k CASES] NAME=SERVER..." >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { echo "usage: $0 [-d DURATION] [-r ROUNDS] [-k CASES] NAME=SERVER..." >&2; exit 2; }
for s in "$@"; do
  case $s in *=*) [ -x "${s#*=}" ] || { echo "not an executable: ${s#*=}" >&2; exit 2; } ;;
    *) echo "not NAME=SERVER: $s" >&2; exit 2 ;; esac
done
[ -x bench/load/load ] || { echo "bench/load/load is missing: go build -o load . in bench/load" >&2; exit 2; }
. bench/lib.sh

case $(uname) in
  Darwin) timeflag=-l; rsspat='maximum resident set size' ;;
  *) timeflag=-v; rsspat='Maximum resident set size' ;;
esac

pg_start
psql "$pg" -q -c "SELECT 1" >/dev/null

round=1
while [ "$round" -le "$rounds" ]; do
  for k in $cases; do
    n=${k%%:*}; rest=${k#*:}; len=${rest%%:*}; c=${rest#*:}
    for s in "$@"; do
      label=${s%%=*}; server=${s#*=}
      timelog="$tmp/time-$label-$round-$n-$len-$c"
      start "$label" ready /usr/bin/time "$timeflag" -o "$timelog" "$server" 8 --port 0 --pg "$pg" --pg-conns 4
      # $pid is time's; the server is its only child.
      spid=$(pgrep -P "$pid")
      pids="$pids $spid"
      before=$(cpu "$spid")
      result=$(bench/load/load -url "http://$addr/rows?n=$n&len=$len" -c "$c" -d "$duration" -body "$n") ||
        { echo "$label n=$n len=$len c=$c $result"; exit 1; }
      after=$(cpu "$spid")
      # SIGTERM to the server (time would not pass it on); it must exit 0.
      kill -TERM "$spid"
      status=0
      wait "$pid" 2>/dev/null || status=$?
      [ "$status" = 0 ] || { echo "$label exited with $status after SIGTERM"; exit 1; }
      rm -f "$tmp/$label"
      reqs=$(echo "$result" | sed -E 's/.* n=([0-9]+).*/\1/')
      rss=$(awk -v pat="$rsspat" 'index($0, pat) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }' "$timelog")
      echo "round=$round $label n=$n len=$len c=$c $result cpu_us_per_req=$(echo "($after - $before) * 1000000 / $reqs" | bc) peak_rss=$rss"
    done
  done
  round=$((round + 1))
done
