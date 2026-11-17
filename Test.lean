import Server.Conn
import Server.H1Adapter
import Server.HandParser
import App.Hello
import App.Fixture
import App.Db
import Corpus

/-! `lsrv-test`: the server's Lean side without sockets. Each adapter (H1, the
production one, and the hand-written comparator) answers the same requests:
framing of every proper prefix, limits at their exact boundaries, status
codes, connection rules, Host and request-target validation (H1 only),
`Expect: 100-continue`, the checks on what the application answers, the
Date header, and the adapter's law (`Adapter.Incremental`): a request fed in
fragments, with the state kept between them, answers as in one call.
Connection scenarios drive `Conn.step` through partial receives,
partial sends, the interim response, the shutdown's `refused` and a handler
that waits for queries. Exit status
1 when any check fails. -/

open Server

/-- 0 need more, 1 respond and keep going, 2 respond and close, 3 interim
response, 4 waits for a query. -/
def resultKind : Reply → UInt8
  | .needMore => 0
  | .continue _ => 3
  | .respond _ _ close => if close then 2 else 1
  | .await .. => 4

def consumed : Reply → Nat
  | .respond n _ _ => n
  | _ => 0

def responseOf : Reply → String
  | .respond _ r _ => String.fromUTF8! r
  | .continue r => String.fromUTF8! r
  | .needMore | .await .. => ""

def statusOf (r : Reply) : String := ((responseOf r).splitOn "\r\n").head!

def bytes (s : String) : ByteArray := s.toUTF8

def big (n : Nat) : String := String.ofList (List.replicate n 'a')

def maxHeadRequest : String :=
  -- A head of exactly maxHeadBytes (8192) bytes before CRLFCRLF.
  let fixed := "GET / HTTP/1.1\r\nHost: a\r\nX: "
  fixed ++ big (maxHeadBytes - fixed.length) ++ "\r\n\r\n"

def maxRequest : String :=
  let fixed := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 8192\r\nX: "
  fixed ++ big (maxHeadBytes - fixed.length) ++ "\r\n\r\n" ++ big maxBodyBytes

/-- A head of 10,000 bytes: a start line and a field block of 5,000 bytes
each, under H1's separate limits but over `maxHeadBytes` in all; with the
largest body it would exceed `inCap`. -/
def splitHead : String :=
  "POST /" ++ big 5000 ++ " HTTP/1.1\r\nHost: a\r\nContent-Length: 8192\r\nX: " ++ big 5000 ++ "\r\n\r\n"

/-- An adapter under test, with `App.Hello` unless a case names another application. -/
structure Adapter where
  name : String
  σ : Type
  make : Response.OwnFields → Handler → Nat → Server.Adapter σ

/-- The adapter's answer to `buf` in one call, from its initial state. -/
def Adapter.handle (ad : Adapter) (own : Response.OwnFields) (app : Handler) (now : Nat) (buf : ByteArray) : Reply :=
  let a := ad.make own app now
  (a.handle a.init buf).2

def h1 : Adapter := { name := "H1", σ := H1Adapter.Parser, make := H1Adapter.adapter }
def hand : Adapter := { name := "hand-written", σ := Unit, make := HandParser.adapter }

structure Case where
  name : String
  request : String
  kind : UInt8
  status : String
  /-- Bytes the request consumes; `none` means the whole input. -/
  consumes : Option Nat := none
  /-- The hand-written parser's answer where it differs from H1's
  (`lsrv-compare` lists every difference); `none` means the same. -/
  hand : Option (UInt8 × String) := none
  app : Handler := App.Hello.app

def cases : List Case := [
  { name := "GET /", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1, status := "HTTP/1.1 200 OK" },
  { name := "HEAD /", request := "HEAD / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1, status := "HTTP/1.1 200 OK" },
  { name := "unknown path", request := "GET /x HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1, status := "HTTP/1.1 404 Not Found" },
  { name := "method case", request := "GeT / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2, status := "HTTP/1.1 501 Not Implemented",
    hand := some (1, "HTTP/1.1 404 Not Found") },
  { name := "POST body, then a pipelined GET", request := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhelloGET / HTTP/1.1\r\nHost: a\r\n\r\n",
    kind := 1, status := "HTTP/1.1 404 Not Found", consumes := some 52 },
  { name := "Connection: close", request := "GET / HTTP/1.1\r\nHost: a\r\nConnection: keep-alive, Close\r\n\r\n", kind := 2, status := "HTTP/1.1 200 OK" },
  { name := "HTTP/1.0 default close", request := "GET / HTTP/1.0\r\n\r\n", kind := 2, status := "HTTP/1.1 200 OK" },
  { name := "HTTP/1.0 keep-alive", request := "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", kind := 1, status := "HTTP/1.1 200 OK" },
  { name := "missing Host", request := "GET / HTTP/1.1\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "two Host", request := "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "bad header name", request := "GET / HTTP/1.1\r\nHost: a\r\nBad Header: x\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "obs-fold", request := "GET / HTTP/1.1\r\nHost: a\r\n x\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "bare LF in a field", request := "GET / HTTP/1.1\r\nHost: a\nX: y\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "HTTP/2.0 line", request := "GET / HTTP/2.0\r\nHost: a\r\n\r\n", kind := 2, status := "HTTP/1.1 505 HTTP Version Not Supported",
    hand := some (2, "HTTP/1.1 400 Bad Request") },
  { name := "conflicting Content-Length", request := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "Content-Length list", request := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1, 1\r\n\r\na", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "chunked", request := "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", kind := 2, status := "HTTP/1.1 501 Not Implemented" },
  { name := "body over the limit", request := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 8193\r\n\r\n", kind := 2, status := "HTTP/1.1 413 Content Too Large" },
  { name := "head of exactly the limit", request := maxHeadRequest, kind := 1, status := "HTTP/1.1 200 OK" },
  { name := "largest request", request := maxRequest, kind := 1, status := "HTTP/1.1 404 Not Found" },
  { name := "head over the limit", request := "GET / HTTP/1.1\r\nHost: a\r\nX: " ++ big 9000 ++ "\r\n\r\n", kind := 2, status := "HTTP/1.1 431 Request Header Fields Too Large" },
  { name := "start line and fields each under the limit, together over it", request := splitHead, kind := 2,
    status := "HTTP/1.1 431 Request Header Fields Too Large" },
  { name := "CONNECT", request := "CONNECT a:443 HTTP/1.1\r\nHost: a:443\r\n\r\n", kind := 2, status := "HTTP/1.1 501 Not Implemented" },
  -- Host syntax and request-target form (RFC 9112 3.2, 3.2.1-3.2.4): H1's checks.
  { name := "Host with a space", request := "GET / HTTP/1.1\r\nHost: a b\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request",
    hand := some (1, "HTTP/1.1 200 OK") },
  { name := "Host with a path", request := "GET / HTTP/1.1\r\nHost: a/b\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request",
    hand := some (1, "HTTP/1.1 200 OK") },
  { name := "Host with a port", request := "GET / HTTP/1.1\r\nHost: a:8083\r\n\r\n", kind := 1, status := "HTTP/1.1 200 OK" },
  { name := "target with a fragment", request := "GET /a#f HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request",
    hand := some (1, "HTTP/1.1 404 Not Found") },
  { name := "asterisk-form for GET", request := "GET * HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request",
    hand := some (1, "HTTP/1.1 404 Not Found") },
  { name := "target without a slash", request := "GET a HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request",
    hand := some (1, "HTTP/1.1 404 Not Found") },
  -- What the application answers is checked before it is written (Server.Response.check).
  { name := "response over maxResponseBytes", request := "GET /too-big HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := App.Fixture.app },
  { name := "response with an owned field", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => .done { status := 200, headers := #[("Content-Length", "1")] } },
  { name := "response field with CRLF", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => .done { status := 200, headers := #[("X", "a\r\nY: b")] } },
  { name := "204 with a body", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => .done { status := 204, body := "x".toUTF8 } },
  { name := "205 with a body", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => .done { status := 205, body := "x".toUTF8 } },
  { name := "205", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1,
    status := "HTTP/1.1 205 Reset Content", app := fun _ => .done { status := 205 } },
  { name := "status 99", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => .done { status := 99 } },
  { name := "echo", request := "POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello", kind := 1,
    status := "HTTP/1.1 200 OK", app := App.Fixture.app },
  -- Expect: 100-continue (RFC 9110 10.1.1): the interim response only while the body is missing.
  { name := "100-continue, body missing", request := "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
    kind := 3, status := "HTTP/1.1 100 Continue", consumes := some 0, hand := some (0, "") },
  { name := "100-continue, part of the body", request := "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhe",
    kind := 3, status := "HTTP/1.1 100 Continue", consumes := some 0, hand := some (0, "") },
  { name := "100-continue, body already sent", request := "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello",
    kind := 1, status := "HTTP/1.1 200 OK", app := App.Fixture.app },
  { name := "100-continue in HTTP/1.0", request := "POST /echo HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
    kind := 0, status := "", consumes := some 0 },
  { name := "100-continue, no body", request := "GET / HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\n\r\n",
    kind := 1, status := "HTTP/1.1 200 OK" }
]

/-- Requests that must frame completely: every proper prefix needs more bytes. -/
def framed : List String :=
  ["GET / HTTP/1.1\r\nHost: a\r\n\r\n", "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello"]

def dates : List (Nat × String) := [
  (0, "Thu, 01 Jan 1970 00:00:00 GMT"),
  (951782400, "Tue, 29 Feb 2000 00:00:00 GMT"),
  (1767225599, "Wed, 31 Dec 2025 23:59:59 GMT"),
  (1793580020, "Mon, 02 Nov 2026 00:40:20 GMT")
]

/-- Counts failed expectations. -/
abbrev Check := StateT Nat IO

def fail (msg : String) : Check Unit := do
  IO.println s!"FAIL {msg}"
  modify (· + 1)

def expectRecv (what : String) (a : Conn.Action) (room : Nat) : Check Unit :=
  match a with
  | .recv r => if r != room then fail s!"{what}: room {r}, want {room}" else pure ()
  | _ => fail s!"{what}: did not ask to receive"

/-- The data and offset of a send, or a failure. -/
def expectSend (what : String) (a : Conn.Action) : Check (Option (ByteArray × Nat)) :=
  match a with
  | .send d off => pure (some (d, off))
  | _ => do fail s!"{what}: did not send"; pure none

def expectClose (what : String) (a : Conn.Action) : Check Unit :=
  match a with
  | .close => pure ()
  | _ => fail s!"{what}: did not close"

/-- One connection through `Conn.step`: a request split in two receives, a
partial send, the rest of the send, the peer closing, and an event after
close. -/
def connScenario (ad : Adapter) : Check Unit := do
  let h := ad.make {} App.Hello.app 0
  let w := s!"conn {ad.name}"
  let part1 := bytes "GET / HTTP/1.1\r\nHo"
  let (s1, a1) := Conn.step h (Conn.initial h) (.received part1)
  expectRecv w a1 (inCap - part1.size)
  let (s2, a2) := Conn.step h s1 (.received (bytes "st: a\r\n\r\n"))
  let some (resp, off) ← expectSend s!"{w}: a complete request" a2 | return
  if off != 0 then fail s!"{w}: the response starts at {off}"
  if s2.buf.size != 0 then fail s!"{w}: the request was not consumed"
  let (s3, a3) := Conn.step h s2 (.sent 10)
  match a3 with
  | .send d 10 => if d.size != resp.size then fail s!"{w}: the rest is another response"
  | _ => fail s!"{w}: a partial send did not continue at offset 10"
  let (s4, a4) := Conn.step h s3 (.sent (resp.size - 10))
  expectRecv s!"{w}: after the response" a4 inCap
  let (s5, a5) := Conn.step h s4 (.received ByteArray.empty)
  expectClose s!"{w}: the peer closing" a5
  match (Conn.step h s5 (.sent 1)).2 with
  | .none => pure ()
  | _ => fail s!"{w}: an event after close was acted on"
  expectClose s!"{w}: a send report while reading" (Conn.step h (Conn.initial h) (.sent 1)).2

/-- `Expect: 100-continue` through `Conn.step` with H1: the interim response is
sent once, also across a partial send and a body arriving in two parts, and
the final response follows the body. -/
def continueScenario : Check Unit := do
  let h := H1Adapter.adapter {} App.Fixture.app 0
  let head := bytes "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"
  let (s1, a1) := Conn.step h (Conn.initial h) (.received head)
  let some (interim, _) ← expectSend "100-continue: the head" a1 | return
  if interim != Response.continueBytes then fail "100-continue: the first send is not the interim response"
  let (s2, a2) := Conn.step h s1 (.sent 5)
  match a2 with
  | .send _ 5 => pure ()
  | _ => fail "100-continue: a partial interim send did not continue"
  let (s3, a3) := Conn.step h s2 (.sent (interim.size - 5))
  expectRecv "100-continue: after the interim response" a3 (inCap - head.size)
  let (s4, a4) := Conn.step h s3 (.received (bytes "he"))
  expectRecv "100-continue: part of the body" a4 (inCap - head.size - 2)
  let (_, a5) := Conn.step h s4 (.received (bytes "llo"))
  let some (final, _) ← expectSend "100-continue: the body" a5 | return
  let text := String.fromUTF8! final
  if !text.startsWith "HTTP/1.1 200 OK" || !text.endsWith "\r\n\r\nhello" then
    fail s!"100-continue: the final response is {repr text}"

/-- Every request the adapter waits for fits in the connection's buffer: a
head over `maxHeadBytes` followed by the largest body, in receives of 1460
bytes, is answered with 431 before the buffer fills, not closed silently. -/
def limitScenario (ad : Adapter) : Check Unit := do
  let h := ad.make {} App.Hello.app 0
  let b := bytes (splitHead ++ big maxBodyBytes)
  let mut s := (Conn.initial h)
  let mut off := 0
  while off < b.size do
    let (s', a) := Conn.step h s (.received (b.extract off (min b.size (off + 1460))))
    off := off + 1460
    match a with
    | .recv _ => s := s'
    | .send d _ =>
      let st := (String.fromUTF8! d).splitOn "\r\n" |>.head!
      if st != "HTTP/1.1 431 Request Header Fields Too Large" then fail s!"limit {ad.name}: answered {st}"
      return
    | _ => fail s!"limit {ad.name}: closed after {off} bytes without an answer"; return
  fail s!"limit {ad.name}: no answer"

/-- The shutdown: a declined receive closes the connection in every live phase. -/
def refusedScenario : Check Unit := do
  let h := H1Adapter.adapter {} App.Hello.app 0
  expectClose "refused while reading" (Conn.step h (Conn.initial h) .refused).2
  let (s, _) := Conn.step h (Conn.initial h) (.received (bytes "GET / HTTP/1.1\r\nHo"))
  expectClose "refused with a partial request" (Conn.step h s .refused).2

def expectQuery (what : String) (a : Conn.Action) (sql : String) (params : Array (Option String)) : Check Unit :=
  match a with
  | .query q => if q.sql != sql || q.params != params then fail s!"{what}: asked {repr q.sql} {q.params}" else pure ()
  | _ => fail s!"{what}: did not ask for a query"

def statusLine (d : ByteArray) : String := ((String.fromUTF8! d).splitOn "\r\n").head!

/-- A handler that waits for queries, through `Conn.step` with H1: `/chain`
asks for a query, continues with its result to a second one built from it,
then sends the response; a request pipelined behind it waits in the buffer
(no receive while querying) and is answered right after. A lost connection
answers 503; a failure report while querying closes. -/
def queryScenario : Check Unit := do
  let h := H1Adapter.adapter {} App.Db.app 0
  let req := "GET /chain HTTP/1.1\r\nHost: a\r\n\r\n"
  let next := "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
  let (s1, a1) := Conn.step h (Conn.initial h) (.received (bytes (req ++ next)))
  expectQuery "query: the first query" a1 "SELECT 1" #[]
  if s1.buf != bytes next then fail "query: the request was not consumed, or the pipelined one was"
  let (s2, a2) := Conn.step h s1 (.answered (.rows #["?column?"] #[#[some "1"]]))
  expectQuery "query: the second query" a2 "SELECT $1::int + 1" #[some "1"]
  let (s3, a3) := Conn.step h s2 (.answered (.rows #["?column?"] #[#[some "2"]]))
  let some (resp, _) ← expectSend "query: the response" a3 | return
  let text := String.fromUTF8! resp
  if statusLine resp != "HTTP/1.1 200 OK" || !text.endsWith "\r\n\r\n2" then fail s!"query: answered {repr text}"
  let (s4, a4) := Conn.step h s3 (.sent resp.size)
  let some (resp2, _) ← expectSend "query: the pipelined request" a4 | return
  if statusLine resp2 != "HTTP/1.1 200 OK" then fail "query: the pipelined request was not answered"
  if s4.buf.size != 0 then fail "query: the pipelined request was not consumed"
  -- A lost connection: 503, and the connection goes on.
  let (s5, _) := Conn.step h (Conn.initial h) (.received (bytes "GET /db?id=42 HTTP/1.1\r\nHost: a\r\n\r\n"))
  let (_, a6) := Conn.step h s5 (.answered (.error "08006" "lost"))
  let some (resp3, _) ← expectSend "query: a lost connection" a6 | return
  if statusLine resp3 != "HTTP/1.1 503 Service Unavailable" then fail s!"query: a lost connection answered {statusLine resp3}"
  expectClose "query: a failure while querying" (Conn.step h s5 .failed).2
  -- An answer out of place (no query asked) closes.
  expectClose "query: an answer while reading" (Conn.step h (Conn.initial h) (.answered (.rows #[] #[]))).2

/-- Two continuations' first steps alike: the same response, or the same query. -/
def sameStep : Await (ByteArray × Bool) → Await (ByteArray × Bool) → Bool
  | .done (a, c), .done (b, d) => a == b && c == d
  | .query q _, .query r _ => q.sql == r.sql && q.params == r.params
  | _, _ => false

/-- Two answers alike: the same kind, bytes consumed and response bytes; a
query's continuation is a function, compared by the query it asks and by its
first step on a row, on no rows and on an error. -/
def sameReply : Reply → Reply → Bool
  | .needMore, .needMore => true
  | .continue a, .continue b => a == b
  | .respond n a c, .respond m b d => n == m && a == b && c == d
  | .await n q k, .await m r l =>
    n == m && q.sql == r.sql && q.params == r.params &&
      [Query.Result.rows #["id", "randomnumber"] #[#[some "42", some "7"]], .rows #[] #[], .error "08006" "lost"].all
        fun res => sameStep (k res) (l res)
  | _, _ => false

/-- The adapter's law (`Adapter.Incremental`): `b` fed in pieces of `k` bytes,
each call with the state the previous one kept while its answer waited (as
`Conn` does), answers every prefix as one call from the initial state does. -/
def lawFor (ad : Adapter) (app : Handler) (what : String) (b : ByteArray) (k : Nat) : Check Unit := do
  let a := ad.make {} app 0
  let mut p := a.init
  let mut e := 0
  while e < b.size do
    e := min b.size (e + k)
    let buf := b.extract 0 e
    let (p', r) := a.handle p buf
    let whole := (a.handle a.init buf).2
    if !sameReply r whole then
      fail s!"{ad.name} law, {what} in pieces of {k} B: at {e} bytes kind {resultKind r} status {statusOf r}, in one call kind {resultKind whole} status {statusOf whole}"
      return
    if !r.waits then return
    -- `Fed` also allows an empty extension: `Conn` asks again about the same
    -- buffer once the interim response is sent.
    let (p'', r') := a.handle p' buf
    if !sameReply r' whole then
      fail s!"{ad.name} law, {what} in pieces of {k} B: asked again at {e} bytes kind {resultKind r'} status {statusOf r'}, in one call kind {resultKind whole} status {statusOf whole}"
      return
    p := p''

def lawCases (ad : Adapter) : Check Unit := do
  for c in cases do
    let b := bytes c.request
    for k in [1, 2, 3, 7, 64] do lawFor ad c.app c.name b k
    -- Every split in two (the second call extends the first's buffer).
    for i in [1:b.size] do
      if b.size ≤ 600 then
        let a := ad.make {} c.app 0
        let (p, r) := a.handle a.init (b.extract 0 i)
        if r.waits then
          let r2 := (a.handle p b).2
          if !sameReply r2 (a.handle a.init b).2 then
            fail s!"{ad.name} law, {c.name} split at {i}: kind {resultKind r2} status {statusOf r2}"
  for (name, req) in Corpus.requests do
    let b := bytes req
    for k in (if b.size ≤ 2000 then [1, 7, 64, 1460] else [64, 1460, 4096]) do
      lawFor ad App.Hello.app name b k

def adapterCases (ad : Adapter) : Check Unit := do
  for c in cases do
    let r := ad.handle {} c.app 0 (bytes c.request)
    let (kind, status) := if ad.name == hand.name then c.hand.getD (c.kind, c.status) else (c.kind, c.status)
    let want := c.consumes.getD (if kind == 0 then 0 else (bytes c.request).size)
    if resultKind r != kind || statusOf r != status || consumed r != want then
      fail s!"{ad.name} {c.name}: kind {resultKind r} status {statusOf r} consumed {consumed r}; want kind {kind} status {status} consumed {want}"
  for req in framed do
    let b := bytes req
    for k in [0:b.size] do
      if resultKind (ad.handle {} App.Hello.app 0 (b.extract 0 k)) != 0 then
        fail s!"{ad.name} prefix {k} of {repr req} did not ask for more bytes"
  -- HEAD: the GET's Content-Length, no body.
  let r := responseOf (ad.handle {} App.Hello.app 0 (bytes "HEAD / HTTP/1.1\r\nHost: a\r\n\r\n"))
  if !r.endsWith "\r\nContent-Length: 13\r\n\r\n" then fail s!"{ad.name} HEAD: {repr r}"

/-! ## Header fields on the server's own responses (`Response.OwnFields`) -/

/-- Two own fields, one name repeated in another spelling, kept in order. -/
def own : Response.OwnFields :=
  { fields := #[("X-Robots-Tag", "noindex, nofollow"), ("x-robots-tag", "noarchive")] }

/-- The statuses only the server writes in `cases`: the parsers' rejections,
CONNECT's 501 and the 500 that replaces an application's response. -/
def ownStatuses : List String := ["400", "413", "414", "431", "500", "501", "505"]

/-- With `own`, every case answers the same bytes as without, except that a
response the server writes itself carries `own`'s fields right after its
Content-Type; the application's responses and the interim `100 Continue` are
unchanged. -/
def ownFieldCases (ad : Adapter) : Check Unit := do
  let lines := String.join (own.fields.toList.map fun (n, v) => s!"{n}: {v}\r\n")
  let ct := "Content-Type: text/plain; charset=utf-8\r\n"
  for c in cases do
    let r0 := responseOf (ad.handle {} c.app 0 (bytes c.request))
    let r1 := responseOf (ad.handle own c.app 0 (bytes c.request))
    let status := ((statusOf (ad.handle {} c.app 0 (bytes c.request))).splitOn " ")[1]?.getD ""
    let want := if ownStatuses.contains status then r0.replace ct (ct ++ lines) else r0
    if ownStatuses.contains status && !r0.contains ct then fail s!"{ad.name} {c.name}: no Content-Type in {repr r0}"
    if r1 != want then fail s!"{ad.name} own fields, {c.name}: {repr r1}, want {repr want}"
  -- The status does not decide: the application's own 400, 500 and 501 carry no own fields.
  for status in [400, 500, 501] do
    let app : Handler := fun _ => .done { status, headers := #[Response.contentType], body := "x".toUTF8 }
    let req := bytes "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
    let r0 := responseOf (ad.handle {} app 0 req)
    let r1 := responseOf (ad.handle own app 0 req)
    if !r0.startsWith s!"HTTP/1.1 {status} " || !r0.endsWith "\r\n\r\nx" || r1 != r0 then
      fail s!"{ad.name} own fields, the application's {status}: {repr r1}"

/-- `n` bytes of `c`, a character of `w` bytes in UTF-8. -/
def fill (c : Char) (w n : Nat) : String := String.ofList (List.replicate (n / w) c)

/-- The rule on own fields, at its boundaries; the size bound keeps every
response of the server's own within `maxResponseBytes`. -/
def ownFieldRule : Check Unit := do
  -- Written `XY: ` value CRLF: 6 bytes besides the value.
  let atCap := Response.maxOwnFieldBytes - 6
  let valid : List (String × Array (String × String)) := [
    ("none", #[]),
    ("a field at the byte cap", #[("XY", fill 'a' 1 atCap)]),
    ("two-byte characters at the byte cap", #[("XY", fill 'ą' 2 atCap)]),
    ("obs-text and HTAB inside", #[("X", "a\tbé")]),
    ("a repeated name", #[("Set-Cookie", "a=1"), ("set-cookie", "b=2")])]
  let invalid : List (String × Array (String × String)) := [
    ("a byte over the cap", #[("XY", fill 'a' 1 (atCap + 1))]),
    ("a two-byte character over the cap", #[("XY", fill 'ą' 2 (atCap + 2))]),
    ("two fields over the cap together", #[("XY", fill 'a' 1 (atCap / 2)), ("XY", fill 'a' 1 (atCap / 2))]),
    ("CR LF in a value", #[("X", "a\r\nY: b")]),
    ("LF in a value", #[("X", "a\nb")]),
    ("NUL in a value", #[("X", "a" ++ String.singleton (Char.ofNat 0) ++ "b")]),
    ("DEL in a value", #[("X", "a" ++ String.singleton (Char.ofNat 127))]),
    ("a leading space", #[("X", " a")]),
    ("a trailing tab", #[("X", "a\t")]),
    ("an empty name", #[("", "a")]),
    ("a space in a name", #[("X Y", "a")]),
    ("CR LF in a name", #[("X\r\nY", "a")]),
    ("Content-Type", #[("content-TYPE", "text/html")]),
    ("an owned field", #[("Connection", "keep-alive")]),
    ("Date", #[("DATE", "x")])]
  for (what, fs) in valid do
    if !Response.ownFieldsValid fs then fail s!"own fields, {what}: rejected"
  for (what, fs) in invalid do
    if Response.ownFieldsValid fs then fail s!"own fields, {what}: accepted"
  -- Every response the server writes itself fits the bounded output with
  -- fields of exactly the cap, at the widest Date (the year 9999).
  let fs := #[("XY", fill 'a' 1 atCap)]
  for status in [400, 413, 414, 431, 501, 505] do
    let r := Response.write 253402300799 { status, headers := #[Response.contentType] ++ fs } true false
    if r.size > maxResponseBytes then fail s!"own fields: {status} is {r.size} bytes"
  let e := Response.internalError {}
  for headOnly in [false, true] do
    let r := Response.write 253402300799 { e with headers := e.headers ++ fs } true headOnly
    if r.size > maxResponseBytes then fail s!"own fields: the 500 is {r.size} bytes"

-- Fields the rule rejects cannot make an `OwnFields`: its `valid` is then false.
example : Response.ownFieldsValid #[("X", "a\r\nY: b")] = false := by decide +kernel
example : Response.ownFieldsValid #[("Content-Type", "text/html")] = false := by decide +kernel

def main : IO UInt32 := do
  let ((), failures) ← (do
    ownFieldRule
    for ad in [h1, hand] do
      adapterCases ad
      ownFieldCases ad
      connScenario ad
      limitScenario ad
      lawCases ad
    continueScenario
    refusedScenario
    queryScenario
    for (secs, want) in dates do
      let got := String.fromUTF8! (Response.pushDate ByteArray.empty secs)
      if got != want then fail s!"date {secs}: {got}, want {want}" : Check Unit).run 0
  IO.println s!"{failures} failures"
  return if failures == 0 then 0 else 1
