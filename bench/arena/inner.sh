#!/bin/sh
# inner.sh tests|bench|db DIR: run.sh runs this in the run's own network and PID
# namespaces (item 53rwgc; docs/reports/httparena-vps.md). Results go to
# DIR/out.
#
# tests: the transport's and the pool's test binaries (zig build test:
#   pg_test and serve_test on epoll and on io_uring, and pg_glue_test).
# bench: for each contender (lsrv-arena on epoll and on io_uring, HttpArena's
#   go-stdlib and go-fasthttp), first the response checks (validate.log),
#   then round 0 (warm-up, not reported) and rounds 1-5 of HttpArena's
#   HTTP/1.1 profiles the server owns, with the generator on the same two
#   CPUs. Each sample starts a fresh server, so its peak memory (VmHWM) is that
#   sample's. The contenders' order rotates each round.
# db: bench/dbpairs.sh, below.
set -eu
phase=$1 d=$2
out=$d/out
mkdir -p "$out"
ip link set lo up
# This namespace's own socket limits: HttpArena's generator needs one local
# port per connection and the servers a backlog for 4096 connections opened
# at once.
sysctl -q -w net.ipv4.ip_local_port_range="1024 65535" net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535
ulimit -n 262144
export LD_LIBRARY_PATH="$d/lib"
. "$d/start-polled.sh"
# run.sh's watcher writes $d/stop when the site fails; its kill of the scope
# fails while the scope is still starting, so every step checks the file.
stopped() { [ ! -e "$d/stop" ] || exit 3; }
stopped

if [ "$phase" = tests ]; then
  status=0
  # pg_glue_test runs no event loop: one binary for both backends.
  for t in pg_test-epoll serve_test-epoll pg_test-io_uring serve_test-io_uring pg_glue_test; do
    stopped
    s=0
    "$d/$t" >"$out/test-$t.log" 2>&1 || s=$?
    echo "$t: exit $s, $(tail -n 1 "$out/test-$t.log")" | tee -a "$out/tests.txt"
    [ $s -eq 0 ] || status=1
  done
  exit $status
fi

if [ "$phase" = db ]; then
  # bench/dbpairs.sh twice, with Go's default GOMAXPROCS and with -g 1 (item
  # akj76n), from db/, which build.sh lays out as the repository. initdb
  # refuses root, so it runs as nobody, writing only under db/tmp: its
  # private cluster takes only a Unix socket there (bench/lib.sh, pg_start),
  # never the host's PostgreSQL.
  # Only what build.sh laid out: not db/tmp, where a cluster left by an
  # interrupted run must keep its own modes.
  chmod go+rx "$d" "$d/db"
  chmod -R go+rX "$d/db/.lake" "$d/db/bench" "$d/lib"
  mkdir -p "$d/db/tmp"
  chown nobody:nogroup "$d/db/tmp"
  dbpairs() { # NAME [ARG...]
    name=$1; shift
    stopped
    (cd "$d/db" && setpriv --reuid=nobody --regid=nogroup --clear-groups \
      env TMPDIR="$d/db/tmp" HOME="$d/db/tmp" sh bench/dbpairs.sh "$@") >"$out/$name.txt" 2>&1 ||
      { echo "$name failed: $(tail -n 3 "$out/$name.txt")"; exit 1; }
  }
  dbpairs dbpairs
  dbpairs dbpairs-g1 -g 1
  exit 0
fi

port=8080
url=http://127.0.0.1:$port
req=$d/requests
server_cmd() {
  case $1 in
    lsrv-epoll) echo "$d/lsrv-arena-epoll 2 --port $port --max-conns 16384" ;;
    lsrv-io_uring) echo "$d/lsrv-arena-io_uring 2 --port $port --max-conns 16384" ;;
    go-stdlib) echo "$d/go-stdlib" ;;
    go-fasthttp) echo "$d/go-fasthttp" ;;
  esac
}
# pid is the server's process, reap the child whose exit status is the
# server's: the server itself, or start_polled's supervisor.
pid= reap= drain= cur=
start() {
  cur=$1 log=$out/server-$1.log
  : >"$log"
  case $1 in
    lsrv-*)
      # lsrv-arena prints "ready" once every loop accepts (zig/src/serve.zig,
      # ekk_serve): the wait reads its output up to that line, and the end of
      # its output (its exit) ends the wait too. The rest of its output goes
      # on into the log.
      rm -f "$d/server.fifo"
      mkfifo "$d/server.fifo"
      # $(server_cmd) is unquoted on purpose: fixed words without spaces.
      $(server_cmd "$1") >"$d/server.fifo" 2>&1 &
      pid=$!
      reap=$pid
      exec 3<"$d/server.fifo"
      up=no
      while IFS= read -r line <&3; do
        printf '%s\n' "$line" >>"$log"
        [ "$line" != ready ] || { up=yes; break; }
      done
      [ $up = yes ] || { echo "$1 exited before ready: $(tail -n 3 "$log")"; exit 1; }
      cat <&3 >>"$log" &
      drain=$!
      exec 3<&-
      ;;
    *)
      # HttpArena's go entries print nothing once listening: start-polled.sh.
      # $(server_cmd) is unquoted on purpose: fixed words without spaces.
      start_polled "$1" "$d" "$url/pipeline" "$log" $(server_cmd "$1") || exit 1
      ;;
  esac
}
# SIGTERM, then the server's exit status: lsrv-arena shuts down gracefully
# and exits 0 (docs/production-contract.md); the go entries handle no signal
# (main.go), so SIGTERM ends them with 128 + 15. Anything else (a crash, an
# error exit) voids the run.
stop() {
  s=0
  kill -TERM "$pid" || { wait "$reap" || s=$?; echo "$cur exited with $s before SIGTERM: $(tail -n 3 "$out/server-$cur.log")"; exit 1; }
  wait "$reap" || s=$?
  if [ -n "$drain" ]; then wait "$drain"; drain=; fi
  case $cur in lsrv-*) want=0 ;; *) want=143 ;; esac
  [ $s -eq $want ] || { echo "$cur exited with $s after SIGTERM, want $want: $(tail -n 3 "$out/server-$cur.log")"; exit 1; }
}
# User plus system CPU ticks of the whole process.
ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat"; }

servers="lsrv-epoll lsrv-io_uring go-stdlib go-fasthttp"
profiles="baseline pipelined limited-conn latency-10k"

# The response checks: validate.sh's baseline and pipelined checks
# (scripts/validate.sh, "Baseline", "Pipelined"), with curl.
check() { # NAME WANT CURL-ARGS...
  name=$1 want=$2; shift 2
  got=$(curl -s "$@") || got="curl failed"
  if [ "$got" = "$want" ]; then echo "PASS $s $name"; else echo "FAIL $s $name: got '$got', want '$want'"; fi >>"$out/validate.log"
}
for s in $servers; do
  stopped
  start "$s"
  check "GET /baseline11?a=13&b=42" 55 "$url/baseline11?a=13&b=42"
  check "POST /baseline11?a=13&b=42 body=20" 75 -d 20 "$url/baseline11?a=13&b=42"
  check "POST /baseline11?a=13&b=42 chunked body=20" 75 -H "Transfer-Encoding: chunked" -d 20 "$url/baseline11?a=13&b=42"
  a=$(awk 'BEGIN { srand(); print int(rand() * 10000) }') b=$(awk 'BEGIN { srand(); print int(rand() * 777) + 1 }')
  check "GET /baseline11?a=$a&b=$b (random)" $((a + b)) "$url/baseline11?a=$a&b=$b"
  check "GET /baseline11 Content-Type" "text/plain" -o /dev/null -w '%{content_type}' "$url/baseline11?a=13&b=42"
  check "GET /pipeline" ok "$url/pipeline"
  check "GET /pipeline Content-Type" "text/plain" -o /dev/null -w '%{content_type}' "$url/pipeline"
  # Sixteen requests pipelined on one connection, as gcannon -p 16 sends them.
  got=$( (for i in $(seq 16); do cat "$req/pipeline.raw"; done) | curl -s --max-time 5 telnet://127.0.0.1:$port 2>/dev/null | grep -c '^ok' || true) # delay: external deadline: curl ends the raw connection after 5 s, since the server keeps it open
  if [ "$got" = 16 ]; then echo "PASS $s 16 pipelined GET /pipeline"; else echo "FAIL $s 16 pipelined GET /pipeline: $got answers"; fi >>"$out/validate.log"
  stop
done
# Every check must pass, except the chunked body on lsrv-arena, which answers
# it 501 (docs/reports/httparena-vps.md); a run with another failure is void.
if grep FAIL "$out/validate.log" | grep -v '^FAIL lsrv-[a-z_]* POST /baseline11?a=13&b=42 chunked body=20:' >&2; then
  echo "a response check failed: no measurement" >&2
  exit 1
fi

generate() { # PROFILE FILE
  case $1 in
    baseline) "$d/gcannon" "$url" --raw "$req/get.raw,$req/post_cl.raw" -c 4096 -t 2 -d 5s -p 1 ;;
    pipelined) "$d/gcannon" "$url/pipeline" -c 4096 -t 2 -d 5s -p 16 ;;
    limited-conn) "$d/gcannon" "$url" --raw "$req/get.raw,$req/post_cl.raw" -c 4096 -t 2 -d 5s -p 1 -r 10 ;;
    latency-10k) "$d/zrk" -t 2 -c 1024 -d 20s -R 10000 --format json --plain "$url/baseline11?a=1&b=2" ;;
  esac >"$2" 2>&1
}

echo "round profile server cpu_ticks vmhwm_kb start end" >"$out/samples.txt"
for round in 0 1 2 3 4 5; do
  # Rotate the contenders' order by the round.
  set -- $servers
  k=0
  while [ $k -lt $((round % 4)) ]; do set -- "$@" "$1"; shift; k=$((k + 1)); done
  order="$*"
  for p in $profiles; do
    for s in $order; do
      stopped
      start "$s"
      t0=$(date +%s.%N) c0=$(ticks "$pid")
      generate "$p" "$out/r$round-$p-$s.txt"
      c1=$(ticks "$pid") t1=$(date +%s.%N)
      hwm=$(awk '/^VmHWM/ { print $2 }' "/proc/$pid/status")
      stop
      echo "$round $p $s $((c1 - c0)) $hwm $t0 $t1" >>"$out/samples.txt"
    done
  done
done
