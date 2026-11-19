import Server.Handler

/-! HttpArena's HTTP/1.1 entry (item 53rwgc): the endpoints of the profiles
this server owns, answered as HttpArena's go-stdlib entry answers them
(`frameworks/go-stdlib/main.go`, `baseline11`, at HttpArena da3ded60952b).

- `GET` or `POST /baseline11?...`: the sum of every query value that is a
  decimal integer, plus, for `POST`, the body when it is one after trimming
  whitespace; values that are not integers count nothing. Integers are
  Go's `int` on x86_64: a value outside 64 bits counts nothing and the sum
  wraps. `text/plain`.
- `GET /pipeline`: `ok`, `text/plain`.
- Anything else: 404.

A query field is split at its first `=`, as Go's `url.ParseQuery` does.
Go also decodes the value first: `+` becomes a space, which `strconv.Atoi`
refuses, so a query value counts only as `-` and digits, or digits alone;
a percent-encoded value (`%31`), which Go would decode to an integer, counts
nothing here, since this server decodes no query (docs/production-contract.md, "Not yet").
HttpArena sends plain decimal values. It sees only `Server.Handler`. -/

namespace App.Arena

def textPlain : Array (String × String) := #[("Content-Type", "text/plain")]
def notFoundBody : ByteArray := "404 page not found\n".toUTF8

def int64Min : Int := -(2 ^ 63)

/-- `n` in Go's 64-bit `int`, if it fits. -/
def fits (n : Int) : Option Int := if int64Min ≤ n ∧ n < 2 ^ 63 then some n else none

/-- A decimal integer with an optional sign that fits 64 bits, as Go's
`strconv.Atoi` reads one (no spaces, no `_`): the POST body. -/
def int? (s : String) : Option Int :=
  (if s.startsWith "+" then (s.drop 1).toString.toNat?.map Int.ofNat else s.toInt?).bind fits

/-- A query value as Go decodes and reads it: `-` and digits, or digits
alone (a `+` would have decoded to a space). -/
def queryInt? (v : String) : Option Int :=
  if v.startsWith "+" then none else int? v

/-- Go's 64-bit wrapping of a sum. -/
def wrap (n : Int) : Int := (n - int64Min) % 2 ^ 64 + int64Min

/-- The sum of the integer values of a query string `a=1&b=2`. A field
without `=` has an empty value, which counts nothing. -/
def querySum (q : String) : Int :=
  (q.splitOn "&").foldl (fun acc field =>
    match field.splitOn "=" with
    | _ :: v :: rest => acc + (queryInt? ("=".intercalate (v :: rest))).getD 0
    | _ => acc) 0

def respond (r : Server.Request) : Server.Response :=
  let (path, query) := match r.target.splitOn "?" with
    | p :: rest => (p, "?".intercalate rest)
    | [] => (r.target, "")
  if path == "/baseline11" && (r.method == "GET" || r.method == "POST") then
    let body := if r.method == "POST" then
      match String.fromUTF8? r.body with
      | some s => (int? s.trimAscii.toString).getD 0
      | none => 0
      else 0
    { status := 200, headers := textPlain, body := (toString (wrap (querySum query + body))).toUTF8 }
  else if path == "/pipeline" && r.method == "GET" then
    { status := 200, headers := textPlain, body := "ok".toUTF8 }
  else { status := 404, headers := textPlain, body := notFoundBody }

def app : Server.Handler := fun r => .done (respond r)

end App.Arena
