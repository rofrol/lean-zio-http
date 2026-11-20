# start-polled.sh: sourced by inner.sh and local-inner.sh, which start
# HttpArena's go entries with it (item 4fued7); start-polled-test.sh checks it.
#
# start_polled NAME DIR URL LOG CMD...: starts CMD, its output going to LOG,
# under a supervisor: a subshell whose only child is CMD, which waits for it,
# writes its exit status to DIR/exit and exits with that status. The go
# entries print nothing once listening (main.go at build.sh's arena_commit:
# ListenAndServe, reuseport.Listen, no output), so this then polls that
# external server with an idempotent request to URL until it answers, at most
# 5000 times. The supervisor's record of CMD's exit ends the wait at the next
# failed request, with that status. The loop this replaced ended on `kill -0`
# failing, which reported no status and held only because dash and bash reap
# an exited child on SIGCHLD (measured on dash 0.5.12, Debian 13's): POSIX
# does not require it, and `kill -0` succeeds on an unreaped child. Sets pid,
# CMD's process (to signal and observe), and reap, the supervisor (to wait
# for: its status is CMD's). Returns 0 once URL answers; otherwise prints why,
# naming NAME, and returns 1, leaving whatever still runs to the caller's
# exit. DIR is the caller's own: it holds the supervisor's fifo and record.
# A supervisor killed before it opens the fifo would leave the caller
# waiting for the pid: nothing here kills it alone (run.sh's scope and
# local.sh's container end the caller with it).
start_polled() {
  sp_name=$1 sp_dir=$2 sp_url=$3 sp_log=$4
  shift 4
  rm -f "$sp_dir/exit" "$sp_dir/exit.new" "$sp_dir/pid.fifo" || return 1
  mkfifo "$sp_dir/pid.fifo" || return 1
  (
    "$@" >"$sp_log" 2>&1 </dev/null &
    echo $! >"$sp_dir/pid.fifo"
    s=0
    wait $! || s=$?
    # A rename, so a reader sees either no record or the whole status; a
    # failed write says so on stderr, and the wait then runs to its bound.
    echo $s >"$sp_dir/exit.new" && mv "$sp_dir/exit.new" "$sp_dir/exit"
    exit $s
  ) >/dev/null </dev/null &
  reap=$!
  read -r pid <"$sp_dir/pid.fifo" || { echo "$sp_name: its supervisor gave no pid"; return 1; }
  rm -f "$sp_dir/pid.fifo"
  sp_i=0
  until curl -s -o /dev/null "$sp_url"; do
    if [ -e "$sp_dir/exit" ]; then
      echo "$sp_name exited with $(cat "$sp_dir/exit") before answering: $(tail -n 3 "$sp_log")"
      return 1
    fi
    sp_i=$((sp_i + 1))
    [ $sp_i -lt 5000 ] || { echo "$sp_name did not answer $sp_url in 5000 requests"; return 1; }
  done
}
