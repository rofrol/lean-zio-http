#!/bin/sh
# The service latency of a second connection on the loop of a connection
# that fills its receive buffer with small pipelined requests (item vhvejg;
# bench/fairness/main.go). Starts lsrv-arena with one loop, so both
# connections share it, and runs the probe alone, then beside a loader of
# each case of Corpus.fullCases. Needs lsrv-arena built (lake build) and Go;
# ARENA names another lsrv-arena binary to measure (another commit's build),
# PROBES the probe requests per run (20000 unless set).
# Measures only: it is in neither check.sh nor bench.sh, and its figures are
# machine-dependent (docs/reports/full-buffer-step.md).
set -eu
cd "$(dirname "$0")/../.."
. bench/lib.sh
(cd bench/fairness && go build -o fairness .)
start lsrv-arena ready "${ARENA:-.lake/build/bin/lsrv-arena}" 1 --port 0
for load in none pipeline 404; do
  bench/fairness/fairness -addr "$addr" -load "$load" -n "${PROBES:-20000}"
done
stop graceful
