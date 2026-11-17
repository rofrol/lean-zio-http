/-! Database queries as values: what a handler asks of PostgreSQL and what it
gets back, and `Await`, a handler's answer that may wait for queries before it
is complete. It imports nothing; `Server.Handler` (the application's side) and
`Server.Wire` (the connection's side) both build on it, and the loop's
PostgreSQL pool (zig/src/pg.zig, through zig/src/pg.c) performs the queries
(README, "PostgreSQL").

Each query is its own implicit transaction, and successive queries of one
request may run on different PostgreSQL sessions. A query must leave its
session outside a transaction: one that leaves a transaction open or failed
(`BEGIN`) is answered `error "25000"` and its session is closed, which rolls
the transaction back. Session state other than transactions (`SET`,
session-level advisory locks, temporary tables) stays with the session and
may be seen by later queries of any request; a query must not change it, nor
deallocate prepared statements (`DEALLOCATE`, `DISCARD ALL`), which the pool
caches per session. A query is never retried by the server: when its
connection is lost, its answer is an error, and whether it took effect is
unknown; a query the pool gives up on after it may have reached the
database is answered `abandoned` (`Query.Result`). -/

namespace Server

/-- One SQL statement and its parameters `$1`, `$2`, … in text form; `none` is
NULL. The SQL and the parameters must not contain a NUL character (the pool
answers such a query with an error without sending it). -/
structure Query where
  sql : String
  params : Array (Option String) := #[]

/-- What PostgreSQL answered, in text form (the pool's client encoding is
UTF-8). -/
inductive Query.Result where
  /-- The statement succeeded: the result columns' names and its rows, `none`
  for NULL; both empty for a statement that returns no rows. -/
  | rows (columns : Array String) (rows : Array (Array (Option String)))
  /-- The statement failed or did not run. `sqlstate` is PostgreSQL's error
  code; the pool's own failures use class 08 (connection exception: `08006`
  when the connection was lost or could not be made, so the statement may or
  may not have run), `54000` (a query the pool cannot send: a NUL character,
  more than 65,535 parameters; it did not run) and `25000` (the statement
  left a transaction open, which closing its session rolled back). An
  `error` does not establish that the statement had no effect, nor that
  sending it again is safe: class 08 may have an unknown outcome as well
  (only `abandoned` says so structurally). -/
  | error (sqlstate : String) (message : String)
  /-- The pool abandoned the statement after it may have reached the
  database, and closed its session before the statement's end, so whether
  it took effect is unknown: a write may have been committed or rolled back,
  and effects outside transactions (sequences) may stay. The server
  promises no rollback, and this answer never authorizes sending the
  statement again: a caller that does so needs its own means (an
  idempotent statement, a key it checks) to know that is safe. `sqlstate`
  and `message` say why: `54000` for a result over `Query.maxResultBytes`
  (the pool stops at the row that crosses the bound). -/
  | abandoned (sqlstate : String) (message : String)
  deriving Inhabited

/-- Most bytes the Lean value of a `rows` result may cost, a larger one
becomes `abandoned "54000"`, whose statement's outcome is unknown
(`Query.Result.abandoned`). The pool receives rows one at a time and charges
each before building it, as a conservative count of the objects it
allocates: the result, each column name, each row (one slot per field, so a
`NULL` or empty value costs its slot) and each value's `some` and string,
with each object's header and rounding, and invalid UTF-8 charged three
times for its replacement characters. So the row and field counts are
bounded too: a result of one column of `NULL`s holds fewer than 22,000 rows.
This bounds the result the pool gathers, not the process's memory: libpq
holds one whole protocol message at a time before the pool sees it, so a
single row larger than the bound is received whole before it is refused,
and the allocator's overhead comes on top. -/
def Query.maxResultBytes : Nat := 1048576

/-- An answer that may wait for queries: `done a`, or `query q k`, which runs
`q` and continues with `k` applied to its result. -/
inductive Await (α : Type) where
  | done (a : α)
  | query (q : Query) (k : Query.Result → Await α)

namespace Await

def map {α β : Type} (f : α → β) : Await α → Await β
  | .done a => .done (f a)
  | .query q k => .query q fun r => (k r).map f

def bind {α β : Type} : Await α → (α → Await β) → Await β
  | .done a, f => f a
  | .query q k, f => .query q fun r => (k r).bind f

instance : Monad Await where
  pure := .done
  bind := bind

/-- Runs `q` and returns its result. -/
def run (q : Query) : Await Query.Result := .query q .done

end Await

end Server
