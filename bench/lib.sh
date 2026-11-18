# Shared by check.sh and bench.sh, which source it from the repository root
# after `set -eu`. It puts PostgreSQL's tools first on PATH, makes the
# temporary directory $tmp (removed on exit with every server started through
# `start` and the cluster started through `pg_start`), and defines the
# helpers below.
PATH="$(pg_config --bindir):$PATH"
# lake links the servers with -lpq from pg_config's libdir.
LIBRARY_PATH="$(pg_config --libdir)${LIBRARY_PATH:+:$LIBRARY_PATH}"
export PATH LIBRARY_PATH

tmp=$(mktemp -d)
pids=""
pgdata=""
cleanup() {
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  if [ -n "$pgdata" ]; then pg_ctl -D "$pgdata" -m immediate stop >/dev/null 2>&1 || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# start NAME READY-TEXT COMMAND...: starts a server and returns once it has
# printed a line containing READY-TEXT (or fails if its output ends first,
# which means it exited, and shows that output). Sets $pid, and $addr to the
# host:port from the server's "listening on HOST:PORT" (or dusty's "Listening
# on HOST:PORT") line, which must come first: the servers are started on a
# port the kernel picks, so concurrent runs of other checks cannot take it.
start() {
  name=$1; ready=$2; shift 2
  mkfifo "$tmp/$name"
  "$@" >"$tmp/$name" 2>&1 &
  pid=$!
  pids="$pids $pid"
  exec 3<"$tmp/$name"
  up=no; addr=""; seen=""
  while IFS= read -r line <&3; do
    seen="$seen$line
"
    case $line in *[Ll]"istening on "*) addr=${line#*istening on }; addr=${addr%% *} ;; esac
    case $line in *"$ready"*) up=yes; break ;; esac
  done
  if [ "$up" != yes ]; then printf '%s exited before it listened; its output:\n%s' "$name" "$seen"; exit 1; fi
  if [ -z "$addr" ]; then printf '%s printed no listening address; its output:\n%s' "$name" "$seen"; exit 1; fi
  cat <&3 >/dev/null &   # keep draining its output
  pids="$pids $!"
  exec 3<&-
}

# stop [graceful]: SIGTERM; with `graceful`, the server must exit with status
# 0 (the Lean servers' shutdown, README "Production contract").
stop() {
  kill -TERM "$pid"
  status=0
  wait "$pid" 2>/dev/null || status=$?
  if [ "${1:-}" = graceful ] && [ "$status" != 0 ]; then echo "$name exited with $status after SIGTERM"; exit 1; fi
}

# pg_start: creates and starts the private cluster (trust authentication on
# its own Unix socket under $tmp only, no TCP listener) with the table world
# filled; sets pgdata, pgopts and pg (the connection string).
pg_start() {
  pgdata="$tmp/pgdata"
  pgopts="-c listen_addresses= -c unix_socket_directories=$tmp -p 5499 -c max_prepared_transactions=4 -c max_connections=200"
  pg="host=$tmp port=5499 user=postgres dbname=postgres"
  # --no-sync: the cluster is disposable, and on the VPS (bench/arena/run.sh
  # db) initdb's fsyncs would hit the production host's disk.
  initdb -D "$pgdata" -U postgres --auth=trust -E UTF8 --no-locale --no-sync >"$tmp/initdb.log" 2>&1 || { cat "$tmp/initdb.log"; exit 1; }
  pg_ctl -D "$pgdata" -w -l "$tmp/pg.log" -o "$pgopts" start >/dev/null
  # The rows of world: randomnumber = (id * 7919) mod 10000 + 1 (42 -> 2599).
  psql "$pg" -q -v ON_ERROR_STOP=1 -c "CREATE TABLE world (id int PRIMARY KEY, randomnumber int NOT NULL);
    INSERT INTO world SELECT i, (i * 7919) % 10000 + 1 FROM generate_series(1, 10000) i; ANALYZE world;"
}
