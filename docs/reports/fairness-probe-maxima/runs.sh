#!/bin/sh
# The traced runs of item srx6tz (docs/reports/fairness-probe-maxima.md): per
# load, lsrv-arena (built with trace.patch, see the report) writes its loop
# trace, the probe its samples, the canary its pauses and top the host's CPU
# by process. Usage: runs.sh OUTDIR LABEL; FAIRNESS_FLAGS adds probe flags
# (-spin). Needs lsrv-arena built with trace.patch and bench/fairness/fairness
# built; it builds the canary into OUTDIR. macOS (kqueue, top's flags).
set -eu
mkdir -p "$1"
out=$(cd "$1" && pwd); label=$2
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../../.."
. bench/lib.sh
go build -o "$out/canary" "$here/canary.go"
for load in none pipeline 404; do
  LSRV_TRACE="$out/server-$label-$load.bin"
  export LSRV_TRACE
  start "arena-$label-$load" ready .lake/build/bin/lsrv-arena 1 --port 0
  unset LSRV_TRACE
  uptime
  # The host's CPU by process, sampled each second: other programs are an
  # external producer that sends no event.
  top -l 0 -s 1 -n 8 -o cpu -stats pid,command,cpu,threads > "$out/top-$label-$load.txt" &
  tpid=$!
  "$out/canary" > "$out/canary-$label-$load.txt" &
  cpid=$!
  # shellcheck disable=SC2086 # FAIRNESS_FLAGS is a list of flags
  bench/fairness/fairness -addr "$addr" -load "$load" -n "${PROBES:-20000}" -trace "$out/probe-$label-$load.txt" ${FAIRNESS_FLAGS:-}
  kill "$cpid" "$tpid" 2>/dev/null || true
  wait "$cpid" || { echo "the canary failed"; exit 1; }
  wait "$tpid" || true
  stop graceful
done
