#!/bin/sh
# local-inner.sh OUT ROUNDS PERF SERVER...: bench/arena/local.sh runs this in
# its privileged container (item 6p6tu6; docs/reports/over-5s-tail.md). A labelled stress diagnostic, not a test:
# HttpArena's baseline (adapted: GET and Content-Length POST templates, no
# chunked POST, as in inner.sh) and pipelined profiles (gcannon, 4096 connections, 5 s)
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
. /s/start-polled.sh
polled=$(mktemp -d)
traced=$(mktemp -d)
port=8080 url=http://127.0.0.1:8080 req=/b/requests
for round in $(seq "$rounds"); do
  for prof in baseline pipelined; do
    for srv in "$@"; do
      tag=$srv-$prof-$round
      case $srv in
        lsrv-*) cmd="/b/$srv 2 --port $port --max-conns 16384" ;;
        *) cmd="/b/$srv" ;;
      esac
      log=$out/server-$tag.log drain=
      case $srv in
        lsrv-*)
          # Read its output up to "ready" (every loop accepts), or to its
          # end (its exit); the rest goes on into the log (inner.sh, start).
          rm -f /tmp/server.fifo; mkfifo /tmp/server.fifo
          # $cmd is unquoted on purpose: fixed words without spaces.
          taskset -c 0,1 $cmd >/tmp/server.fifo 2>&1 &
          pid=$!
          reap=$pid
          exec 3</tmp/server.fifo
          : >"$log"; up=no
          while IFS= read -r line <&3; do
            printf '%s\n' "$line" >>"$log"
            [ "$line" != ready ] || { up=yes; break; }
          done
          [ $up = yes ] || { echo "$srv exited before ready:"; cat "$log"; exit 1; }
          cat <&3 >>"$log" &
          drain=$!
          exec 3<&-
          ;;
        *)
          # HttpArena's go entries print nothing once listening:
          # start-polled.sh sets pid and reap.
          start_polled "$srv" "$polled" "$url/pipeline" "$log" taskset -c 0,1 $cmd || exit 1
          ;;
      esac
      # Created here, so the wait below reads it before bpftrace opens it.
      : >"$out/trace-$tag.txt"
      ns=$(stat -L -c %i /proc/self/ns/net)
      start_supervised "$traced" "$out/trace-$tag.txt" bpftrace -B line /s/trace.bt "$(echo "$srv" | cut -c1-6)" "$ns" || exit 1
      bt=$sv_pid bt_reap=$sv_reap
      # trace.bt prints "ready" once a connection was seen by all its probes;
      # each curl makes one, at most 5000, and the supervisor's record of
      # bpftrace's exit ends the wait (start-polled.sh).
      i=0
      until grep -q '^ready$' "$out/trace-$tag.txt"; do
        [ ! -e "$traced/exit" ] || { echo "bpftrace exited with $(cat "$traced/exit") before attaching:"; cat "$out/trace-$tag.txt"; exit 1; }
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
      # After SIGINT, bpftrace prints its maps and exits 0, and perf record
      # writes its data and ends with 130 (128 + SIGINT's 2); anything else is
      # an error exit or a crash, or the tool ended before the signal, its
      # trace or profile then missing or cut short (measured in this container
      # on 2026-11-20, item cmb7vk: docs/reports/over-5s-tail.md).
      s=0
      kill -INT $bt || { wait $bt_reap || s=$?; echo "bpftrace exited with $s before SIGINT:"; tail -n 5 "$out/trace-$tag.txt"; exit 1; }
      c1=$(awk '{ print $14 + $15 }' /proc/$pid/stat)
      wait $bt_reap || s=$?
      [ $s -eq 0 ] || { echo "bpftrace exited with $s after SIGINT, want 0:"; tail -n 5 "$out/trace-$tag.txt"; exit 1; }
      if [ -n "$pf" ]; then
        s=0
        kill -INT $pf || { wait $pf || s=$?; echo "perf record exited with $s before SIGINT"; exit 1; }
        wait $pf || s=$?
        [ $s -eq 130 ] || { echo "perf record exited with $s after SIGINT, want 130"; exit 1; }
      fi
      # lsrv-arena exits 0 after SIGTERM (its graceful shutdown); the go
      # entries handle no signal, so SIGTERM ends them with 128 + 15
      # (inner.sh, stop). Anything else is a crash or an error exit.
      s=0
      kill -TERM $pid || { wait $reap || s=$?; echo "$srv exited with $s before SIGTERM:"; tail -n 5 "$log"; exit 1; }
      wait $reap || s=$?
      [ -z "$drain" ] || wait $drain
      case $srv in lsrv-*) want=0 ;; *) want=143 ;; esac
      [ $s -eq $want ] || { echo "$srv exited with $s after SIGTERM, want $want:"; tail -n 5 "$log"; exit 1; }
      g() { awk -v k="$1" '$1 == k { print $2 }' "$out/trace-$tag.txt"; }
      resp=$(awk '/requests in/ { print $1 }' "$out/gc-$tag.txt")
      echo "$tag cpu_ticks=$((c1 - c0)) responses=$resp over5s=$(awk '/overflow/ { print $NF }' "$out/gc-$tag.txt")" \
        "p50/p99/p99.9=$(awk '/Latency  / { print $3 "/" $5 "/" $6 }' "$out/gc-$tag.txt")" \
        "accepted_during_load=$(g @accepted:)/$(g @established:) accept_max_ms=$(g @max_ms:) accepted_after_1s=$(g @over_1s:) accepted_after_5s=$(g @over_5s:)" | tee -a "$out/summary.txt"
    done
  done
done
