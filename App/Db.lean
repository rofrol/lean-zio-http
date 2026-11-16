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
- `GET /lock?key=K`: `SELECT pg_advisory_xact_lock_shared(K)`, which waits
  while a test holds the exclusive lock K; answered `released`.
- `GET /bad`: a query PostgreSQL cannot prepare (no such column), answered
  `database error 42703`.
- `GET /div?d=N`: `SELECT 1 / $1::int`, answered with the quotient or, for
  d=0, `database error 22012`.
- `GET /begin`: `BEGIN`, which leaves a transaction open, answered
  `database error 25000` (`Server.Query`).
- `GET /` and the rest: `App.Hello`, with no query.

A failed query is answered 503 when the database could not be reached or the
connection was lost (SQLSTATE class 08) and 500 otherwise, with the SQLSTATE
as the body. -/

namespace App.Db

open Server

def text (status : Nat) (body : String) : Response :=
  { status, headers := App.Hello.textPlain, body := body.toUTF8 }

def json (body : String) : Response :=
  { status := 200, headers := #[("Content-Type", "application/json")], body := body.toUTF8 }

def failed (sqlstate : String) : Response :=
  text (if sqlstate.startsWith "08" then 503 else 500) s!"database error {sqlstate}\n"

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
  | .error .. => none

def world (id : Nat) : Await Response := do
  match ← Await.run { sql := "SELECT id, randomnumber FROM world WHERE id = $1", params := #[some (toString id)] } with
  | .error st _ => pure (failed st)
  | .rows _ rows =>
    match rows[0]? with
    | some #[some i, some n] => pure (json s!"\{\"id\":{i},\"randomNumber\":{n}}")
    | _ => pure (text 404 "no such row\n")

def chain : Await Response := do
  match ← Await.run { sql := "SELECT 1" } with
  | .error st _ => pure (failed st)
  | r@(.rows ..) =>
    match ← Await.run { sql := "SELECT $1::int + 1", params := #[(first r).join] } with
    | .error st _ => pure (failed st)
    | r2 => pure (text 200 (((first r2).join).getD "null"))

def lock (key : Nat) : Await Response := do
  match ← Await.run { sql := "SELECT pg_advisory_xact_lock_shared($1)", params := #[some (toString key)] } with
  | .error st _ => pure (failed st)
  | .rows .. => pure (text 200 "released")

/-- One query whose first field is the answer. -/
def single (q : Query) : Await Response := do
  match ← Await.run q with
  | .error st _ => pure (failed st)
  | r => pure (text 200 (((first r).join).getD "null"))

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
    | some k => if k < 2 ^ 62 then lock k else .done (text 400 "bad key\n")
    | none => .done (text 400 "bad key\n")
  | "/bad" => single { sql := "SELECT no_such_column FROM world" }
  | "/div" =>
    match (param r.target "d").bind String.toInt? with
    | some d => single { sql := "SELECT 1 / $1::int", params := #[some (toString d)] }
    | none => .done (text 400 "bad d\n")
  | "/begin" => single { sql := "BEGIN" }
  | _ => .done (App.Hello.respond r)

end App.Db
