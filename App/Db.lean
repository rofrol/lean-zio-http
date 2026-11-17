import Server.Handler
import App.Hello

/-! The database application of `lsrv-db`, for the PostgreSQL benchmark and
tests (bench/dbcheck, bench.sh). The table is `world (id int primary key,
randomnumber int)`, filled by bench.sh.

- `GET /db?id=N`: one primary-key SELECT, answered as
  `{"id":N,"randomNumber":M}`; 404 when there is no such row. Go's
  `bench/pgserver` answers the same.
- `GET /chain`: two queries, the second built from the first's result
  (`SELECT 1`, then `SELECT $1::int + 1`), answered `2`.
- `GET /lock?key=K[&ms=N]`: `SELECT pg_advisory_xact_lock_shared(K)`, which
  waits while a test holds the exclusive lock K; answered `released`. `ms`
  is the query's completion budget (`Query.timeoutMs`), the server's default
  without it.
- `GET /bad`: a query PostgreSQL cannot prepare (no such column), answered
  `database error 42703`.
- `GET /div?d=N`: `SELECT 1 / $1::int`, answered with the quotient or, for
  d=0, `database error 22012`.
- `GET /begin`: `BEGIN`, which leaves a transaction open, answered
  `database error 25000` (`Server.Query`).
- `GET /insert?n=N`: inserts N rows of 1,000 bytes into the table `big
  (v text)`, which bench/dbcheck creates, returning them, answered with the
  number of rows returned; past about 1,000 rows the result is over
  `Query.maxResultBytes`, which the pool abandons (`Query.Result.abandoned`),
  answered `database error 54000, outcome unknown`.
- `GET /rows?n=N[&len=L]`: N rows of L bytes (100 by default) from
  `generate_series`, answered with the number of rows returned; for
  bench/rows.sh, which measures the cost of collecting many rows.
- `GET /` and the rest: `App.Hello`, with no query.

A failed query is answered 503 when the database could not be reached or the
connection was lost (SQLSTATE class 08), 504 when its deadline or
PostgreSQL's `statement_timeout` ended it (`57014`) and 500 otherwise, with
the SQLSTATE as the body; an abandoned one (`Query.Result.abandoned`) is
answered with the same status, its body adding `, outcome unknown`. -/

namespace App.Db

open Server

def text (status : Nat) (body : String) : Response :=
  { status, headers := App.Hello.textPlain, body := body.toUTF8 }

def json (body : String) : Response :=
  { status := 200, headers := #[("Content-Type", "application/json")], body := body.toUTF8 }

def status (sqlstate : String) : Nat :=
  if sqlstate.startsWith "08" then 503 else if sqlstate == "57014" then 504 else 500

def failed (sqlstate : String) : Response :=
  text (status sqlstate) s!"database error {sqlstate}\n"

/-- A query the pool abandoned: whether it took effect is unknown. -/
def abandoned (sqlstate : String) : Response :=
  text (status sqlstate) s!"database error {sqlstate}, outcome unknown\n"

/-- The value of `name` in the request-target's query, as sent. -/
def param (target name : String) : Option String :=
  match target.splitOn "?" with
  | [_, q] => (q.splitOn "&").findSome? fun kv =>
      match kv.splitOn "=" with
      | [k, v] => if k == name then some v else none
      | _ => none
  | _ => none

def path (target : String) : String := (target.splitOn "?").headD target

/-- The first field of the first row, if any. -/
def first : Query.Result → Option (Option String)
  | .rows _ rows => rows[0]? >>= (·[0]?)
  | .error .. | .abandoned .. => none

def world (id : Nat) : Await Response := do
  match ← Await.run { sql := "SELECT id, randomnumber FROM world WHERE id = $1", params := #[some (toString id)] } with
  | .error st _ => pure (failed st)
  | .abandoned st _ => pure (abandoned st)
  | .rows _ rows =>
    match rows[0]? with
    | some #[some i, some n] => pure (json s!"\{\"id\":{i},\"randomNumber\":{n}}")
    | _ => pure (text 404 "no such row\n")

def chain : Await Response := do
  match ← Await.run { sql := "SELECT 1" } with
  | .error st _ => pure (failed st)
  | .abandoned st _ => pure (abandoned st)
  | r@(.rows ..) =>
    match ← Await.run { sql := "SELECT $1::int + 1", params := #[(first r).join] } with
    | .error st _ => pure (failed st)
    | .abandoned st _ => pure (abandoned st)
    | r2 => pure (text 200 (((first r2).join).getD "null"))

def lock (key : Nat) (timeoutMs : Option Nat) : Await Response := do
  match ← Await.run { sql := "SELECT pg_advisory_xact_lock_shared($1)", params := #[some (toString key)], timeoutMs } with
  | .error st _ => pure (failed st)
  | .abandoned st _ => pure (abandoned st)
  | .rows .. => pure (text 200 "released")

/-- One query whose first field is the answer. -/
def single (q : Query) : Await Response := do
  match ← Await.run q with
  | .error st _ => pure (failed st)
  | .abandoned st _ => pure (abandoned st)
  | r => pure (text 200 (((first r).join).getD "null"))

def insert (n : Nat) : Await Response := do
  match ← Await.run { sql := "INSERT INTO big (v) SELECT repeat('x', 1000) FROM generate_series(1, $1::int) RETURNING v",
                      params := #[some (toString n)] } with
  | .error st _ => pure (failed st)
  | .abandoned st _ => pure (abandoned st)
  | .rows _ rows => pure (text 200 (toString rows.size))

def rows (n len : Nat) : Await Response := do
  match ← Await.run { sql := "SELECT repeat('x', $2::int) FROM generate_series(1, $1::int)",
                      params := #[some (toString n), some (toString len)] } with
  | .error st _ => pure (failed st)
  | .abandoned st _ => pure (abandoned st)
  | .rows _ rows => pure (text 200 (toString rows.size))

def app : Handler := fun r =>
  if r.method != "GET" then .done (App.Hello.respond r) else
  match path r.target with
  | "/db" =>
    match (param r.target "id").bind String.toNat? with
    | some id => if id < 2 ^ 31 then world id else .done (text 400 "bad id\n")
    | none => .done (text 400 "bad id\n")
  | "/chain" => chain
  | "/lock" =>
    match (param r.target "key").bind String.toNat? with
    | some k =>
      if k ≥ 2 ^ 62 then .done (text 400 "bad key\n") else
      match param r.target "ms" with
      | none => lock k none
      | some ms => match ms.toNat? with
        | some n => lock k (some n)
        | none => .done (text 400 "bad ms\n")
    | none => .done (text 400 "bad key\n")
  | "/bad" => single { sql := "SELECT no_such_column FROM world" }
  | "/div" =>
    match (param r.target "d").bind String.toInt? with
    | some d => single { sql := "SELECT 1 / $1::int", params := #[some (toString d)] }
    | none => .done (text 400 "bad d\n")
  | "/begin" => single { sql := "BEGIN" }
  | "/insert" =>
    match (param r.target "n").bind String.toNat? with
    | some n => if n < 2 ^ 31 then insert n else .done (text 400 "bad n\n")
    | none => .done (text 400 "bad n\n")
  | "/rows" =>
    let len := match param r.target "len" with
      | none => some 100
      | some l => l.toNat?
    match (param r.target "n").bind String.toNat?, len with
    | some n, some l => if n < 2 ^ 31 ∧ l < 2 ^ 31 then rows n l else .done (text 400 "bad n or len\n")
    | _, _ => .done (text 400 "bad n or len\n")
  | _ => .done (App.Hello.respond r)

end App.Db
