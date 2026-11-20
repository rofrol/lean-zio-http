# start-polled.sh: sourced by inner.sh and local-inner.sh, which start
# HttpArena's go entries with start_polled (item 4fued7), bpftrace with
# start_supervised (item cmb7vk) and perf record with start_controlled (item
# 6lqxi5); start-polled-test.sh checks them.
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

# start_controlled DIR LOG CMD...: starts CMD, a command that takes its
# commands on the fifo DIR/ctl and answers each with "ack" on the fifo DIR/ack
# (perf record's --control fifo:DIR/ctl,DIR/ack; item 6lqxi5), sends it
# "enable" and waits for its "ack". Its output goes to LOG. DIR is the
# caller's own, one controlled command at a time; the fifos are made afresh,
# so nothing a previous command left unread reaches this one. The caller holds
# DIR/ctl on fd 4, opened read-write (on Linux and macOS such an open does
# not wait for the other end, fifo(7)), so its writes never block, and reads
# DIR/ack on fd 5. A wrapper, a subshell whose only child is CMD, holds a
# writer of DIR/ack and writes "exit N" (CMD's status) there when CMD ends:
# that line is the record of CMD's exit, and once the wrapper and CMD are
# gone a read of fd 5 ends at the end of file, so the caller waits for
# neither if the wrapper dies without its record. Sets sc_reap, the wrapper
# (to wait for: its status is CMD's). Returns 0 on the "ack"; returns 1 when
# CMD exited first (sc_exit is its status, also 0: no "ack", no recording)
# or the setup failed (sc_exit says so); the caller then exits, or waits for
# sc_reap and closes fds 4 and 5 itself.
start_controlled() {
  sc_dir=$1 sc_log=$2 sc_exit="unknown (setting up $1 failed)"
  shift 2
  rm -f "$sc_dir/ctl" "$sc_dir/ack" || return 1
  mkfifo "$sc_dir/ctl" "$sc_dir/ack" || return 1
  exec 4<>"$sc_dir/ctl" 5<>"$sc_dir/ack"
  # `|| s=$?`, so a caller's set -e cannot skip the record. CMD opens the
  # fifos itself, by name.
  (
    s=0
    "$@" >"$sc_log" 2>&1 </dev/null 4>&- 5>&- || s=$?
    echo "exit $s" >&5
    exit $s
  ) >/dev/null </dev/null 4>&- &
  sc_reap=$!
  # Opened while fd 5 still writes to it, so the open does not wait; fd 5
  # then keeps only this reader.
  exec 5<"$sc_dir/ack"
  control_cmd enable
}

# control_cmd WORD: sends WORD to start_controlled's command and reads its
# answer: "ack" returns 0; the wrapper's "exit N" sets sc_exit to N and
# returns 1, as does anything else, sc_exit saying what.
control_cmd() {
  echo "$1" >&4
  IFS= read -r sc_line <&5 || { sc_exit="unknown ($sc_dir/ack ended without the wrapper's record)"; return 1; }
  case $sc_line in
    ack) return 0 ;;
    "exit "*) sc_exit=${sc_line#exit } ;;
    *) sc_exit="unknown (it answered \"$sc_line\" to $1)" ;;
  esac
  return 1
}

# stop_controlled: sends "stop" to start_controlled's command, waits for its
# "ack", then for the wrapper, and closes fds 4 and 5. Sets sc_exit to the
# status; returns 0 when the command acknowledged the stop and exited 0,
# 1 otherwise (an exit before the "ack" also fails, whatever its status).
# Without the "ack" it waits for nothing: the command may still run (an
# unexpected answer), and the caller exits.
stop_controlled() {
  sc_st=0
  if control_cmd stop; then
    sc_exit=0
    wait $sc_reap || sc_exit=$?
    [ $sc_exit -eq 0 ] || sc_st=1
  else
    sc_st=1
  fi
  exec 4>&- 5>&-
  return $sc_st
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
