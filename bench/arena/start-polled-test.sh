#!/bin/sh
# The check of start-polled.sh (items 4fued7, cmb7vk), which ./check.sh runs; it needs
# only a POSIX shell. A stand-in curl on PATH fails until its OK_AT-th call
# (never with OK_AT=0) and counts its calls, so no network is used.
# - An early exit: a server that exits 7 at once, never answering. The wait
#   must end with "exited with 7" well before the 5000 requests, and the
#   supervisor must record and return 7. The loop this replaced fails here
#   on the missing status only: dash and bash reap the exited child on
#   SIGCHLD, so its `kill -0` failed early too (start-polled.sh).
# - A successful readiness: a server that runs until SIGTERM, answering at the
#   third request. The wait must return 0 after exactly three, with pid the
#   server's process: SIGTERM to pid ends it, and the supervisor records and
#   returns 128 + 15. The supervisor's shell may report that SIGTERM on
#   stderr ("Terminated"): it is this case's own signal.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
. "$here/start-polled.sh"
mkdir "$scratch/bin"
cat >"$scratch/bin/curl" <<'EOF'
#!/bin/sh
n=$(($(cat "$CURL_CALLS") + 1))
echo $n >"$CURL_CALLS"
[ "$OK_AT" -gt 0 ] && [ $n -ge "$OK_AT" ]
EOF
chmod +x "$scratch/bin/curl"
PATH=$scratch/bin:$PATH
export CURL_CALLS="$scratch/calls"
fail() { echo "start-polled-test: $*"; exit 1; }

echo 0 >"$CURL_CALLS"
export OK_AT=0
status=0
start_polled early "$scratch" http://unused/ "$scratch/early.log" sh -c 'echo early-out; exit 7' >"$scratch/early.out" || status=$?
# Its server has exited: the trap must not signal that pid.
pid=
out=$(cat "$scratch/early.out")
[ $status -eq 1 ] || fail "early exit: start_polled returned $status, want 1; it printed: $out"
[ "$out" = "early exited with 7 before answering: early-out" ] || fail "early exit: start_polled printed: $out"
[ "$(cat "$CURL_CALLS")" -lt 5000 ] || fail "early exit: the wait went on to the bound ($(cat "$CURL_CALLS") requests)"
status=0
wait "$reap" || status=$?
[ $status -eq 7 ] || fail "early exit: the supervisor exited $status, want 7"
[ "$(cat "$scratch/exit")" = 7 ] || fail "early exit: the supervisor recorded $(cat "$scratch/exit"), want 7"

echo 0 >"$CURL_CALLS"
export OK_AT=3
# The stand-in server runs until SIGTERM ends it: it opens a fifo nobody
# writes to; the test, or its exit, sends that signal.
mkfifo "$scratch/never"
start_polled ready "$scratch" http://unused/ "$scratch/ready.log" cat "$scratch/never" >"$scratch/ready.out" ||
  fail "readiness: start_polled failed: $(cat "$scratch/ready.out")"
[ "$(cat "$CURL_CALLS")" = 3 ] || fail "readiness: $(cat "$CURL_CALLS") requests, want 3"
[ ! -e "$scratch/exit" ] || fail "readiness: an exit was recorded while the server runs: $(cat "$scratch/exit")"
[ "$pid" != "$reap" ] || fail "readiness: pid is the supervisor's"
kill -TERM "$pid"
status=0
wait "$reap" || status=$?
pid=
[ $status -eq 143 ] || fail "readiness: the supervisor exited $status after SIGTERM to the server, want 143"
[ "$(cat "$scratch/exit")" = 143 ] || fail "readiness: the supervisor recorded $(cat "$scratch/exit"), want 143"
# start_supervised alone, as local-inner.sh starts bpftrace: readiness is
# CMD's own output, and the record must hold CMD's status, not the
# supervisor's shell's.
start_supervised "$scratch" "$scratch/sv.log" sh -c 'echo sv-out; exit 3' >"$scratch/sv.out" ||
  fail "start_supervised failed: $(cat "$scratch/sv.out")"
[ "$sv_pid" != "$sv_reap" ] || fail "start_supervised: sv_pid is the supervisor's"
status=0
wait "$sv_reap" || status=$?
[ $status -eq 3 ] || fail "start_supervised: the supervisor exited $status, want 3"
[ "$(cat "$scratch/exit")" = 3 ] || fail "start_supervised: the supervisor recorded $(cat "$scratch/exit"), want 3"
[ "$(cat "$scratch/sv.log")" = sv-out ] || fail "start_supervised: the log holds: $(cat "$scratch/sv.log")"
echo "start-polled-test: ok"
