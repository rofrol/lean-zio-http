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
# - bpftrace's stop fifo and perf record's control protocol (item 6lqxi5),
#   with grep and a stand-in, below. The shell may report the SIGKILL of the
#   "wrapper killed" case on stderr ("Killed"): it is that case's own signal.
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

# bpftrace's stop in local-inner.sh: its -c command, grep, ends on the line
# "stop" written to a fifo the caller holds read-write. Written here before
# grep starts, so the line must wait in the fifo for grep's open.
mkfifo "$scratch/stop"
exec 6<>"$scratch/stop"
echo stop >&6
start_supervised "$scratch" "$scratch/stop.log" grep -qx stop "$scratch/stop" >"$scratch/stop.out" ||
  fail "stop fifo: start_supervised failed: $(cat "$scratch/stop.out")"
status=0
wait "$sv_reap" || status=$?
exec 6>&-
[ $status -eq 0 ] || fail "stop fifo: grep exited $status, want 0"

# start_controlled and stop_controlled, as local-inner.sh drives perf record:
# a stand-in takes its commands on DIR/ctl and answers on DIR/ack, as MODE
# says; every exit, early or late, must end the caller's wait with the
# stand-in's status, and an exit before the "ack" fails even with status 0.
cat >"$scratch/bin/ctlstub" <<'EOF'
#!/bin/sh
mode=$1
[ "$mode" != early ] || { echo early-out; exit 7; }
exec 7<"$2" 8>"$3"
while IFS= read -r c <&7; do
  case $mode:$c in
    noack:enable | nostopack:stop) exit 0 ;;
    bogus:stop) echo bogus >&8; exit 6 ;;
    *:enable) echo ack >&8; [ "$mode" != dies ] || exit 3 ;;
    *:stop) echo ack >&8; [ "$mode" != failafterstop ] || exit 5; exit 0 ;;
  esac
done
exit 9
EOF
chmod +x "$scratch/bin/ctlstub"
ctl() { start_controlled "$scratch" "$scratch/ctl.log" ctlstub "$1" "$scratch/ctl" "$scratch/ack"; }
# Exits 7 before it opens either fifo.
status=0; ctl early || status=$?
[ $status -eq 1 ] && [ "$sc_exit" = 7 ] || fail "early: start_controlled returned $status, sc_exit $sc_exit; want 1 and 7"
status=0; wait "$sc_reap" || status=$?
[ $status -eq 7 ] || fail "early: the wrapper exited $status, want 7"
[ "$(cat "$scratch/ctl.log")" = early-out ] || fail "early: the log holds: $(cat "$scratch/ctl.log")"
exec 4>&- 5>&-
# Reads "enable", exits 0 without acknowledging it.
status=0; ctl noack || status=$?
[ $status -eq 1 ] && [ "$sc_exit" = 0 ] || fail "noack: start_controlled returned $status, sc_exit $sc_exit; want 1 and 0"
wait "$sc_reap" || true
exec 4>&- 5>&-
# Acknowledges "enable" and "stop", then exits 0.
ctl ok || fail "ok: start_controlled failed, sc_exit $sc_exit"
stop_controlled || fail "ok: stop_controlled failed, sc_exit $sc_exit"
[ "$sc_exit" = 0 ] || fail "ok: sc_exit $sc_exit, want 0"
# Acknowledges "enable", then exits 3 before the stop. Started outside an
# `||` list, so set -e holds in the wrapper: its record must still come.
ctl dies
status=0; stop_controlled || status=$?
[ $status -eq 1 ] && [ "$sc_exit" = 3 ] || fail "dies: stop_controlled returned $status, sc_exit $sc_exit; want 1 and 3"
# Exits 0 on "stop" without acknowledging it.
ctl nostopack || fail "nostopack: start_controlled failed, sc_exit $sc_exit"
status=0; stop_controlled || status=$?
[ $status -eq 1 ] && [ "$sc_exit" = 0 ] || fail "nostopack: stop_controlled returned $status, sc_exit $sc_exit; want 1 and 0"
# Acknowledges "stop", then exits 5.
ctl failafterstop || fail "failafterstop: start_controlled failed, sc_exit $sc_exit"
status=0; stop_controlled || status=$?
[ $status -eq 1 ] && [ "$sc_exit" = 5 ] || fail "failafterstop: stop_controlled returned $status, sc_exit $sc_exit; want 1 and 5"
# Answers "stop" with something else, then exits 6: the answer, not the
# status behind it, is what the caller must report.
ctl bogus || fail "bogus: start_controlled failed, sc_exit $sc_exit"
status=0; stop_controlled || status=$?
[ $status -eq 1 ] && [ "$sc_exit" = 'unknown (it answered "bogus" to stop)' ] ||
  fail "bogus: stop_controlled returned $status, sc_exit $sc_exit"
# The wrapper killed while the stand-in runs, so no record comes: once the
# stand-in exits (on "stop", unacknowledged), the read ends at the end of
# file instead of waiting.
ctl nostopack || fail "wrapper killed: start_controlled failed, sc_exit $sc_exit"
kill -KILL "$sc_reap"
status=0; wait "$sc_reap" || status=$?
[ $status -eq 137 ] || fail "wrapper killed: the wrapper exited $status, want 137"
status=0; stop_controlled || status=$?
case $status:$sc_exit in
  "1:unknown ($scratch/ack ended without the wrapper's record)") ;;
  *) fail "wrapper killed: stop_controlled returned $status, sc_exit $sc_exit" ;;
esac
echo "start-polled-test: ok"
