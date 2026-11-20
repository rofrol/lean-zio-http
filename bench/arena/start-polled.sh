# start-polled.sh: sourced by inner.sh and local-inner.sh, which start
# HttpArena's go entries with start_polled (item 4fued7) and bpftrace with
# start_supervised (item cmb7vk); start-polled-test.sh checks both.
#
# start_supervised DIR LOG CMD...: starts CMD, its output going to LOG,
# under a supervisor: a subshell whose only child is CMD, which waits for it,
# writes its exit status to DIR/exit and exits with that status. Sets sv_pid,
# CMD's process (to signal and observe), and sv_reap, the supervisor (to wait
# for: its status is CMD's). DIR/exit appearing is the record of CMD's exit:
# a caller's wait for CMD's readiness ends on it, with that status. The loop
# start_polled replaced ended on `kill -0` failing, which reported no status
# and held only because dash and bash reap an exited child on SIGCHLD
# (measured on dash 0.5.12, Debian 13's): POSIX does not require it, and
# `kill -0` succeeds on an unreaped child. Returns 1, saying so, when the
# supervisor gives no pid. DIR is the caller's own, one per supervised
# command at a time: it holds the supervisor's fifo and record. A supervisor
# killed before it opens the fifo would leave the caller waiting for the pid:
# nothing here kills it alone (run.sh's scope and local.sh's container end
# the caller with it).
start_supervised() {
  sv_dir=$1 sv_log=$2
  shift 2
  rm -f "$sv_dir/exit" "$sv_dir/exit.new" "$sv_dir/pid.fifo" || return 1
  mkfifo "$sv_dir/pid.fifo" || return 1
  (
    "$@" >"$sv_log" 2>&1 </dev/null &
    echo $! >"$sv_dir/pid.fifo"
    s=0
    wait $! || s=$?
    # A rename, so a reader sees either no record or the whole status; a
    # failed write says so on stderr, and the caller's wait then runs to its
    # bound.
    echo $s >"$sv_dir/exit.new" && mv "$sv_dir/exit.new" "$sv_dir/exit"
    exit $s
  ) >/dev/null </dev/null &
  sv_reap=$!
  read -r sv_pid <"$sv_dir/pid.fifo" || { echo "$1: its supervisor gave no pid"; return 1; }
  rm -f "$sv_dir/pid.fifo"
}

# start_polled NAME DIR URL LOG CMD...: starts CMD with start_supervised.
# The go entries print nothing once listening (main.go at build.sh's
# arena_commit: ListenAndServe, reuseport.Listen, no output), so this then
# polls that external server with an idempotent request to URL until it
# answers, at most 5000 times; the supervisor's record of CMD's exit ends the
# wait at the next failed request, with that status. Sets pid and reap
# (start_supervised's sv_pid and sv_reap). Returns 0 once URL answers;
# otherwise prints why, naming NAME (CMD's first word when its supervisor
# gave no pid), and returns 1, leaving whatever still runs to the caller's
# exit.
start_polled() {
  sp_name=$1 sp_dir=$2 sp_url=$3 sp_log=$4
  shift 4
  start_supervised "$sp_dir" "$sp_log" "$@" || return 1
  pid=$sv_pid reap=$sv_reap
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
