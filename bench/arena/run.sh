#!/bin/sh
# run.sh tests|bench: the VPS side of the HttpArena runs (item 53rwgc;
# README, "HttpArena on the VPS"). Run as root from the directory
# bench/arena/build.sh filled and copied to the host; it writes only under
# that directory (out/) and starts only processes of its own.
#
# Everything runs in one transient systemd scope of its own
# (lsrv-arena-53rwgc.scope: at most 900 MB of memory, no swap, 4096 tasks,
# so the run cannot push the host's services out of memory) and in fresh
# network and PID namespaces (unshare): the servers listen only on that
# namespace's loopback, unreachable from the network, and the socket limits
# inner.sh widens (port range, listen backlog) are that namespace's, not the
# host's. Ending the scope ends every process of the run.
#
# Meanwhile this script watches the production site (the condition the
# coordinating session set on 2026-11-17): one request to its health URL at a
# time, a second apart. The first answer other than 200, or slower than 1 s,
# kills the scope and ends the run with status 3; the owner decides whether
# it resumes. Every probe goes to out/health-PHASE.log.
set -eu
[ $# -eq 1 ] && case $1 in tests|bench) ;; *) false ;; esac || { echo "usage: $0 tests|bench"; exit 2; }
phase=$1
d=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$d/out"
health=http://127.0.0.1:8083/
scope=lsrv-arena-53rwgc
log=$d/out/health-$phase.log
rm -f "$d/stop" "$d/done"
probe() { curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}' "$health" || echo "000 5"; } # delay: external deadline: a probe of the site gives up after 5 s
echo "# time code seconds when" >"$log"
for i in $(seq 20); do echo "$(date +%s.%N) $(probe) before" >>"$log"; done

# The watcher, bounded at 4 hours of probes.
(
  i=0
  while [ ! -e "$d/done" ] && [ $i -lt 14400 ]; do
    r=$(probe)
    echo "$(date +%s.%N) $r during" >>"$log"
    code=${r% *} t=${r#* }
    if [ "$code" != 200 ] || [ "$(awk -v t="$t" 'BEGIN { print (t > 1.0) }')" = 1 ]; then
      echo "site check failed: $r" >"$d/stop"
      systemctl kill --signal=KILL "$scope.scope" 2>/dev/null || true
      exit 0
    fi
    i=$((i + 1))
    sleep 1 # delay: external polling: the production site's server (ekklesiai.org's lsrv-site service), once a second
  done
) &
watcher=$!

status=0
systemd-run --scope --quiet --unit="$scope" -p MemoryMax=900M -p MemorySwapMax=0 -p TasksMax=4096 \
  unshare --net --pid --fork --mount-proc --kill-child sh "$d/inner.sh" "$phase" "$d" || status=$?
touch "$d/done"
wait "$watcher"
for i in $(seq 5); do echo "$(date +%s.%N) $(probe) after" >>"$log"; done
if [ -e "$d/stop" ]; then
  cat "$d/stop"
  exit 3
fi
exit $status
