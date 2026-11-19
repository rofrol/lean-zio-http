#!/bin/sh
# local-inner.sh OUT ROUNDS PERF SERVER...: bench/arena/local.sh runs this in
# its privileged container (item 6p6tu6; docs/reports/over-5s-tail.md). A labelled stress diagnostic, not a test:
# HttpArena's baseline and pipelined profiles (gcannon, 4096 connections, 5 s)
# against each SERVER (a binary in /b), with the server and the generator
# pinned to the same two CPUs (0 and 1), as on the VPS (inner.sh), and
# trace.bt beside each sample. PERF=1 adds a CPU profile of each lsrv sample
# (perf record, call graphs). Results go to OUT.
set -eu
out=$1 rounds=$2 perf=$3
shift 3
mkdir -p "$out"
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
echo -1 >/proc/sys/kernel/perf_event_paranoid
sysctl -q -w net.ipv4.ip_local_port_range="1024 65535" net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535
ulimit -n 262144
port=8080 url=http://127.0.0.1:8080 req=/b/requests
for round in $(seq "$rounds"); do
  for prof in baseline pipelined; do
    for srv in "$@"; do
      tag=$srv-$prof-$round
      case $srv in
        lsrv-*) cmd="/b/$srv 2 --port $port --max-conns 16384" ;;
        *) cmd="/b/$srv" ;;
      esac
      # $cmd is unquoted on purpose: fixed words without spaces.
      taskset -c 0,1 $cmd >"$out/server-$tag.log" 2>&1 &
      pid=$!
      # Retries an idempotent request until the server answers, at most 5000
      # times; the server's exit ends the wait too (inner.sh).
      i=0
      until curl -s -o /dev/null "$url/pipeline"; do
        kill -0 $pid 2>/dev/null || { echo "$srv exited before answering"; exit 1; }
        i=$((i + 1)); [ $i -lt 5000 ] || { echo "$srv did not answer"; exit 1; }
      done
      : >"$out/trace-$tag.txt"
      ns=$(stat -L -c %i /proc/self/ns/net)
      bpftrace -B line /s/trace.bt "$(echo "$srv" | cut -c1-6)" "$ns" >"$out/trace-$tag.txt" 2>&1 &
      bt=$!
      # trace.bt prints "ready" once a connection was seen by all its probes;
      # each curl makes one, at most 5000, and bpftrace's exit ends the wait.
      i=0
      until grep -q '^ready$' "$out/trace-$tag.txt"; do
        kill -0 $bt 2>/dev/null || { echo "bpftrace failed:"; cat "$out/trace-$tag.txt"; exit 1; }
        i=$((i + 1)); [ $i -lt 5000 ] || { echo "bpftrace did not attach"; exit 1; }
        curl -s -o /dev/null "$url/pipeline" || true
      done
      pf=
      if [ "$perf" = 1 ] && [ "${srv#lsrv-}" != "$srv" ]; then
        perf record -q -F 999 -g -p $pid -o "$out/perf-$tag.data" >/dev/null 2>&1 &
        pf=$!
      fi
      c0=$(awk '{ print $14 + $15 }' /proc/$pid/stat)
      case $prof in
        baseline) taskset -c 0,1 gcannon "$url" --raw "$req/get.raw,$req/post_cl.raw" -c 4096 -t 2 -d 5s -p 1 ;;
        pipelined) taskset -c 0,1 gcannon "$url/pipeline" -c 4096 -t 2 -d 5s -p 16 ;;
      esac >"$out/gc-$tag.txt" 2>&1
      # The trace ends with the generator, before perf writes its data
      # (seconds, while the server goes on accepting): a connection the trace
      # counts as established and not accepted was not accepted during the load.
      kill -INT $bt
      c1=$(awk '{ print $14 + $15 }' /proc/$pid/stat)
      wait $bt || true
      [ -z "$pf" ] || { kill -INT $pf; wait $pf || true; }
      kill -TERM $pid; wait $pid || true
      g() { awk -v k="$1" '$1 == k { print $2 }' "$out/trace-$tag.txt"; }
      resp=$(awk '/requests in/ { print $1 }' "$out/gc-$tag.txt")
      echo "$tag cpu_ticks=$((c1 - c0)) responses=$resp over5s=$(awk '/overflow/ { print $NF }' "$out/gc-$tag.txt")" \
        "p50/p99/p99.9=$(awk '/Latency  / { print $3 "/" $5 "/" $6 }' "$out/gc-$tag.txt")" \
        "accepted_during_load=$(g @accepted:)/$(g @established:) accept_max_ms=$(g @max_ms:) accepted_after_1s=$(g @over_1s:) accepted_after_5s=$(g @over_5s:)" | tee -a "$out/summary.txt"
    done
  done
done
