# PostgreSQL

A handler that answers `Await.query q k` puts its connection in
`Conn.Phase.querying k`; the loop runs `q` on its own pool and feeds the
result back as `Conn.Event.answered`, and `k`'s answer continues the
connection (another query or the response). The connection does nothing
else meanwhile; the loop serves its other connections (`Conn.step_query`,
`bench/dbcheck`'s slow-query test).

- **Pool.** Each loop has its own pool of at most `--pg-conns` libpq
  connections in non-blocking mode, registered with its own `zio.ev` loop
  only (no locks, no sharing between loops; one loop's busy pool does not
  borrow another's idle connections). A query that finds no idle
  connection waits in the loop's FIFO queue, which holds at most one query
  per HTTP connection. Connections open on demand, while queries wait and a
  slot is free, one at a time per loop: a connect is not tied to a query,
  and the connection it opens serves the queue's head like any idle one.
  So a burst on a cold pool opens its connections one after another.
  zio's socket registry keeps a registration per descriptor until a
  `NetClose`, while libpq closes and replaces its own socket, so the pool
  polls a duplicate of libpq's descriptor that it owns and closes with
  `NetClose` (`zig/src/pg.zig`, its header).
- **Statements.** Each connection prepares a statement for each distinct
  `Query.sql` on its first use (one round trip: Prepare, execute and Sync in
  libpq's pipeline mode) and executes it by name after that, as pgx does;
  past 64 statements on a connection further texts run unnamed. So a query
  must not deallocate statements (`DEALLOCATE`, `DISCARD ALL`). An
  execution of a cached statement that fails with `0A000` or `26000` fails
  that query with PostgreSQL's error, which is not resent, and the statement
  is forgotten: the text's next use prepares it again, under a name the
  connection never used. These two SQLSTATEs cover a statement gone stale
  (its result type changed after a schema change is `0A000`; one the server
  no longer has is `26000`) and other errors as well, since PostgreSQL
  documents nothing narrower; a good statement forgotten costs a fresh
  Prepare. Before that query is answered, the forgotten statement is closed
  on the server (a Close with its own Sync, one more round trip), so the
  server holds only the statements the connection caches; a connection
  whose Close fails, or that is lost during it, or whose query's deadline
  (or the shutdown drain) ends during it, is closed and the query answered
  with its own error, never replayed: its execution failed without effect,
  and only the statement's cleanup is uncertain, so it stays an `error`,
  not `abandoned 57014` (decided 2026-11-17, item ncvxfx).
  Parameters and results are text; one statement per query.
- **Results and errors.** Every query is answered exactly once: rows (text
  values, `none` for NULL, invalid UTF-8 replaced), PostgreSQL's error with
  its SQLSTATE, a pool error (`Query.Result.error`): `08006` when the
  connection could not be made, or was found lost before the query was
  handed to libpq (`ekk_pg_send` checks the connection's status before
  any libpq call), `57014` when the query's deadline passed before it was
  sent, `22023` for a `Query.timeoutMs` outside 1 to the ceiling, `54000`
  for a query that cannot be sent (a NUL byte, more than 65,535
  parameters), none of which ran; or the query abandoned
  (`Query.Result.abandoned`): `08006` when the connection was lost after
  the query was handed to libpq (also for a query in flight when the
  server restarts: libpq documents no point before which a failed send or
  an unflushed buffer proves nothing reached the server), `57014` when its
  deadline passed after that ("Deadlines"), and `54000` for a result over
  `Query.maxResultBytes` (1 MiB, charged for every object of its Lean
  value before it is built: each row and field, `NULL` and empty ones
  included, and each string with its header). Rows
  are received in chunks of 16 (libpq's chunked-rows mode; libpq hands a
  chunk over once it is full or the rows have ended) and each row is
  charged before it is built; at the row that crosses the bound the rows
  gathered are released, the query is answered `abandoned "54000"` once
  and its session is closed without reading the rest. So whether the statement took effect
  is unknown (a write with a large `RETURNING` may have been committed, or
  rolled back when the server noticed the closed connection; effects
  outside transactions, such as sequences, stay). `abandoned` says that
  structurally, so a caller need not read the message; it promises no
  rollback and never authorizes sending the statement again, which only
  the caller's own means (an idempotent statement, a key it checks) can
  make safe. An `error` does not prove the opposite in general (PostgreSQL's
  own errors are its own word); an unknown outcome the pool knows of is
  answered `abandoned`. A query is never retried: once it may have reached
  the server, a lost connection or an expiry abandons it, and its outcome
  is unknown (a write may have been committed); the next query opens a
  fresh connection. Likewise a process
  that ends after a query was sent leaves its outcome to PostgreSQL, as
  for any client that disconnects. A connect that fails (or reaches its
  deadline) while no connection of the pool is busy fails every query
  waiting at that moment, each once with `08006`; a query submitted later
  starts the next connect. While connections are busy, the queries waiting
  wait for them instead, each to its own deadline, and no connect starts
  until one of them gets a complete answer from the database (rows or
  PostgreSQL's error), which then serves the queue and lets a connect start
  again; when the last busy connection ends without such an answer (lost,
  expired, closed), the queue fails once with `08006`. So with the database down a loop has at most one connect
  in flight, and a flood of requests is answered from it rather than with
  a connect each; there are no retries, backoff or circuit breaker, so this
  bounds concurrent connects, not their rate while the database stays down.
  `App.Db` answers class 08 with 503, `57014` with 504, other errors with
  500, and an abandoned query with the same status and `outcome unknown`
  in its body.
- **Deadlines.** Each budget is an external database budget, configurable
  from 1 ms to below 2^31 ms (another value: exit status 2). A query's
  completion deadline runs from its submission to the pool to its complete
  result, queueing and connecting included: `--pg-query-ms` 5,000 by
  default; a handler may ask for another with `Query.timeoutMs`, up to
  `--pg-query-max-ms` 5,000 (a value of 0 or over it is answered `error
  22023` unsent). A connect has `--pg-connect-ms` 5,000 from its start to a
  connection ready for queries, enforced by the pool's timer around libpq's
  asynchronous connect (libpq's `connect_timeout` does not bound
  `PQconnectPoll`); a query waiting for it keeps its own earlier deadline.
  Every session starts with PostgreSQL's `statement_timeout` at
  `--pg-statement-ms` 4,000, through libpq's `options` startup parameter
  after the conninfo's own `options` (or `PGOPTIONS`); a conninfo or
  `PGSERVICE` naming a service is refused at startup, since the service
  file's options would be replaced, and so are options ending in an
  unpaired backslash, which would escape the appended one. So PostgreSQL usually ends a long
  statement itself (`error 57014`, the session serves on), but that does
  not bound the pool's wait: queueing, transmission and the server's
  scheduling come before its timer starts. One timer per pool is armed for
  the earliest deadline; its callback expires what is due at that moment
  and re-arms. A query that expires in the queue (or while the connect
  runs) is unlinked and answered `error 57014`; one already handed to libpq
  is answered `abandoned 57014` and its session closed at once with
  PQfinish, without PQcancel: the backend may run on until its
  `statement_timeout` or until it next writes to the closed connection, a
  write may commit, and the query is never sent again. One whose own
  answer is already known, with only the Close of a forgotten statement
  pending, is answered with that answer instead and its session closed the
  same way ("Statements"). A connect that ends
  at its deadline fails the queries waiting with `08006`, as a failed
  connect does. Expiry is judged against the pool's state when the timer's
  callback runs (the waiter still queued, the slot still busy with it, the
  slot still connecting), so an expiry whose completion came first finds
  nothing due and changes nothing; which of a due timer and a ready result
  wins is the order zio runs their callbacks in, as for the connections'
  deadlines. The expiry reaches the handler as the query's result, and its
  response is the handler's: no response byte of the request is sent while
  its query runs, so `App.Db`'s 504 is always possible.
- **Liveness.** An idle connection keeps its receive armed, so a connection
  the server closed is ended when the loop handles its EOF. This is best
  effort: a query the loop dispatches before handling the EOF is answered
  `08006`: `error` when libpq already knew the connection had failed,
  `abandoned` once it was handed to libpq.
- **Sessions.** Each query is its own implicit transaction. A query that
  leaves a transaction open or failed (`BEGIN`) is answered `25000` and its
  session is closed, which rolls the transaction back, so no query runs in
  another's transaction. Other session state (`SET`, session-level advisory
  locks, temporary tables) stays with the session for later queries of any
  request; queries must not change it (`Server.Query`).
- **Connection string.** `--pg` is a libpq conninfo; the pool adds
  `client_encoding=UTF8` and the `options` that set `statement_timeout`
  ("Deadlines"). It must name a Unix socket directory or a
  `hostaddr`: libpq resolves a host name synchronously, which would block
  the loop.
- **Tests.** `bench/dbcheck` runs `lsrv-db` against the private cluster.
  What a real cluster cannot force is tested deterministically by
  `zig build test` in `zig/` (`bench.sh` runs it). `src/pg_test.zig` runs
  `pg.zig`'s pool on a real loop and real sockets with a scripted fake in
  place of `pg.c`: a partial flush with both polls outstanding and the
  write completion arriving after the slot went idle, output that collect
  queued (a Close) flushed before its results are awaited and a connection
  lost then delivering the query's answer, a session ended
  (COPY) with both polls outstanding, synchronous chains of 10,000
  failing queries (no slots, the database down) that stay iterative and
  let a receive ready on the same loop run before they end, each result
  delivered once, a query submitted while one waits for its turn queued
  behind it (and, after the drain's end, also one already waiting, run
  to their end at once),
  deadlines (an expiry in the queue unlinks only that query, a busy
  query's expiry closes its session without reading, which never serves
  again, a connect's deadline fails its waiters, a waiter's own earlier
  deadline, a timer callback after the completion changing nothing, a
  budget refused with `22023`, the drain's end), a lost connection before
  the query reached libpq (`error`) and after (`abandoned`: a failed send,
  flush or read), and a connect failing while a session is busy: the queue
  waits, no connect starts until that session's answer serves it, a
  connect's deadline follows the same rule, a session lost without an
  answer fails the queue once with `08006`, and a waiting query still ends
  at its own deadline.
  `src/pg_glue_test.c` runs `pg.c` and the real libpq against a fake
  PostgreSQL server on a Unix socket, each reply delivered whole, a message
  at a time and a byte at a time: command boundaries and Sync, errors,
  COPY in and out, a transaction left open, a connection lost mid-reply,
  cached statements forgotten (`0A000` from any routine and `26000` forget
  the statement and close it on the server before the answer, more than 64
  of them keep the session, a failed Close or a connection lost during it
  closes the session with the query's own error, a failed transaction closes
  it with no Close sent), and
  chunked collection, in chunks of 1, 2 and 16 rows: after every piece the
  rows held are exactly the whole chunks of the rows received (first use,
  cached and unnamed executions; two full chunks and a partial one),
  zero rows keep their columns, rows then an error answer the error, also
  after a full chunk, a result at exactly the bound is answered, and one
  byte over it, or a single field over it, ends the session once the
  chunk holding the row that crosses it arrives, in a full chunk or the
  last partial one (an oversized first row followed by five more: at that
  row with chunks of 1, at the second row with chunks of 2, at the end of
  the rows with chunks of 16, never later), answered `abandoned`
  (constructor 2), while a query with a NUL character is an `error 54000`
  (constructor 1) that sends nothing. A connection lost mid-reply is
  `abandoned 08006`, one whose EOF libpq saw before the next query refuses
  it unsent (`error 08006`), and every session's startup packet carries
  the startup options (`ekk_pg_options`: merged with the conninfo's or
  `PGOPTIONS`, refused for a service or for options ending in an unpaired
  backslash).
  `bench/dbcheck` checks the deadlines against the private cluster (a query
  expiring in flight and in the queue, `statement_timeout`, a connect to a
  listener that never answers, the shutdown's drain ending with a query
  running and one queued: both connections closed unanswered, the session
  closed without a cancel) and changes a column's type under a cached statement and back,
  and runs an `INSERT ... RETURNING` over the bound (abandoned with
  `54000`, the session closed, the insert wholly applied or not at all).
  A chain of queries that fail synchronously, each asked again from its
  error, runs inside the `submit` that started it for its first
  `chain_inline` (64) results; the rest goes on from later turns of the
  loop, which serves its other ready work in between, so a long chain may
  outlive the `submit` that started it (decided 2026-11-18, item rtkla3;
  `zig/src/pg.zig`, `chain_inline` and `Pool.yieldChain`). After the
  shutdown's drain has ended (`Pool.abort`) a chain runs to its end at
  once, since the drain then closes every connection.
- **Bounded only in part:** the pool gathers at most `Query.maxResultBytes`
  of a result, but libpq copies a chunk's rows into its own result before
  the pool sees them: the chunk that holds the row crossing the bound, up
  to 16 rows of any size, the 15 after it included. So one row larger than
  the bound costs its full size (in libpq's input buffer and again in its
  result) before the session is closed, and so may up to 15 rows after the
  row that crosses it, where single-row mode stopped at that row. libpq's
  input buffer also holds whatever more of the reply had arrived from the
  socket when the session closed (never parsed into rows), and keeps the
  size of the largest message a session received until the session is
  closed. The chunk size, 16 (`EKK_CHUNK_ROWS` in `zig/src/pg.c`), was
  chosen with `bench/rows.sh` against single-row mode
  ([PostgreSQL measurements](reports/postgresql-throughput.md)).
