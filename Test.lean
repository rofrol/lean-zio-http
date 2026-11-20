import Server.Conn
import Server.Transport
import Server.H1Adapter
import Server.HandParser
import App.Hello
import App.Arena
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
partial sends, the interim response, the shutdown's `refused`, a handler
that waits for queries, and the deadlines' expiries. On the corpus `lsrv-bench` measures, both parsers
consume the same bytes, and its fragmented requests are answered. The pool's
result bound in `zig/src/pg.c` equals `Query.maxResultBytes`. Exit status
1 when any check fails. -/

open Server

/-- 0 need more, 1 respond and keep going, 2 respond and close, 3 interim
response, 4 waits for a query. -/
def resultKind : Reply → UInt8
  | .needMore _ => 0
  | .continue _ => 3
  | .respond _ f => if (f 0).2 then 2 else 1
  | .await .. => 4

def consumed : Reply → Nat
  | .respond n _ => n
  | _ => 0

def responseOf : Reply → String
  | .respond _ f => String.fromUTF8! (f 0).1
  | .continue r => String.fromUTF8! r
  | .needMore _ | .await .. => ""

def statusOf (r : Reply) : String := ((responseOf r).splitOn "\r\n").head!

def bytes (s : String) : ByteArray := s.toUTF8

open Corpus (big maxHeadRequest maxRequest)

/-- A GET of `target`. -/
def getOf (target : String) : String := s!"GET {target} HTTP/1.1\r\nHost: a\r\n\r\n"

/-- `n` copies of `s` separated by `sep`. -/
def sepBy (sep s : String) (n : Nat) : String := sep.intercalate (List.replicate n s)

/-- A head of 10,000 bytes: a start line and a field block of 5,000 bytes
each, under H1's separate limits but over `maxHeadBytes` in all; with the
largest body it would exceed `inCap`. -/
def splitHead : String :=
  "POST /" ++ big 5000 ++ s!" HTTP/1.1\r\nHost: a\r\nContent-Length: {maxBodyBytes}\r\nX: " ++ big 5000 ++ "\r\n\r\n"

/-- An adapter under test, with `App.Hello` unless a case names another application. -/
structure Adapter where
  name : String
  σ : Type
  make : Response.OwnFields → Handler → Server.Adapter σ

/-- The adapter's answer to `buf` in one call, from its initial state. -/
def Adapter.handle (ad : Adapter) (own : Response.OwnFields) (app : Handler) (buf : ByteArray) : Reply :=
  let a := ad.make own app
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
  { name := "body over the limit", request := s!"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: {maxBodyBytes + 1}\r\n\r\n", kind := 2, status := "HTTP/1.1 413 Content Too Large" },
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
  -- Element counts of the request-target (`H1Adapter.maxPathSegments`,
  -- `maxQueryParams`), empty elements counted: at the limit served, over it 414.
  { name := "255 path segments", request := getOf ("/" ++ sepBy "/" "a" 255), kind := 1, status := "HTTP/1.1 404 Not Found" },
  { name := "256 path segments", request := getOf ("/" ++ sepBy "/" "a" 256), kind := 2, status := "HTTP/1.1 414 URI Too Long",
    hand := some (1, "HTTP/1.1 404 Not Found") },
  { name := "255 empty path segments", request := getOf (sepBy "" "/" 255), kind := 1, status := "HTTP/1.1 404 Not Found" },
  { name := "256 empty path segments", request := getOf (sepBy "" "/" 256), kind := 2, status := "HTTP/1.1 414 URI Too Long",
    hand := some (1, "HTTP/1.1 404 Not Found") },
  { name := "1,000 query parameters", request := getOf ("/?" ++ sepBy "&" "a=1" 1000), kind := 1, status := "HTTP/1.1 404 Not Found" },
  { name := "1,001 query parameters", request := getOf ("/?" ++ sepBy "&" "a=1" 1001), kind := 2, status := "HTTP/1.1 414 URI Too Long",
    hand := some (1, "HTTP/1.1 404 Not Found") },
  { name := "1,000 empty query parameters", request := getOf ("/?" ++ sepBy "&" "" 1000), kind := 1, status := "HTTP/1.1 404 Not Found" },
  { name := "1,001 empty query parameters", request := getOf ("/?" ++ sepBy "&" "" 1001), kind := 2, status := "HTTP/1.1 414 URI Too Long",
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
  let h := ad.make {} App.Hello.app
  let w := s!"conn {ad.name}"
  let part1 := bytes "GET / HTTP/1.1\r\nHo"
  let (s1, a1) := Conn.step h 0 (Conn.initial h) (.received part1)
  expectRecv w a1 (inCap - part1.size)
  let (s2, a2) := Conn.step h 0 s1 (.received (bytes "st: a\r\n\r\n"))
  let some (resp, off) ← expectSend s!"{w}: a complete request" a2 | return
  if off != 0 then fail s!"{w}: the response starts at {off}"
  if s2.buf.size != 0 then fail s!"{w}: the request was not consumed"
  let (s3, a3) := Conn.step h 0 s2 (.sent 10)
  match a3 with
  | .send d 10 => if d.size != resp.size then fail s!"{w}: the rest is another response"
  | _ => fail s!"{w}: a partial send did not continue at offset 10"
  let (s4, a4) := Conn.step h 0 s3 (.sent (resp.size - 10))
  expectRecv s!"{w}: after the response" a4 inCap
  let (s5, a5) := Conn.step h 0 s4 (.received ByteArray.empty)
  expectClose s!"{w}: the peer closing" a5
  match (Conn.step h 0 s5 (.sent 1)).2 with
  | .none => pure ()
  | _ => fail s!"{w}: an event after close was acted on"
  expectClose s!"{w}: a send report while reading" (Conn.step h 0 (Conn.initial h) (.sent 1)).2

/-- `Expect: 100-continue` through `Conn.step` with H1: the interim response is
sent once, also across a partial send and a body arriving in two parts, and
the final response follows the body. -/
def continueScenario : Check Unit := do
  let h := H1Adapter.adapter {} App.Fixture.app
  let head := bytes "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"
  let (s1, a1) := Conn.step h 0 (Conn.initial h) (.received head)
  let some (interim, _) ← expectSend "100-continue: the head" a1 | return
  if interim != Response.continueBytes then fail "100-continue: the first send is not the interim response"
  let (s2, a2) := Conn.step h 0 s1 (.sent 5)
  match a2 with
  | .send _ 5 => pure ()
  | _ => fail "100-continue: a partial interim send did not continue"
  let (s3, a3) := Conn.step h 0 s2 (.sent (interim.size - 5))
  expectRecv "100-continue: after the interim response" a3 (inCap - head.size)
  let (s4, a4) := Conn.step h 0 s3 (.received (bytes "he"))
  expectRecv "100-continue: part of the body" a4 (inCap - head.size - 2)
  let (_, a5) := Conn.step h 0 s4 (.received (bytes "llo"))
  let some (final, _) ← expectSend "100-continue: the body" a5 | return
  let text := String.fromUTF8! final
  if !text.startsWith "HTTP/1.1 200 OK" || !text.endsWith "\r\n\r\nhello" then
    fail s!"100-continue: the final response is {repr text}"

/-- Every request the adapter waits for fits in the connection's buffer: a
head over `maxHeadBytes` followed by the largest body, in receives of 1460
bytes, is answered with 431 before the buffer fills, not closed silently. -/
def limitScenario (ad : Adapter) : Check Unit := do
  let h := ad.make {} App.Hello.app
  let b := bytes (splitHead ++ big maxBodyBytes)
  let mut s := (Conn.initial h)
  let mut off := 0
  while off < b.size do
    let (s', a) := Conn.step h 0 s (.received (b.extract off (min b.size (off + 1460))))
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
  let h := H1Adapter.adapter {} App.Hello.app
  expectClose "refused while reading" (Conn.step h 0 (Conn.initial h) .refused).2
  let (s, _) := Conn.step h 0 (Conn.initial h) (.received (bytes "GET / HTTP/1.1\r\nHo"))
  expectClose "refused with a partial request" (Conn.step h 0 s .refused).2

/-- The deadline `s` runs under, and its generation. -/
def expectDeadline (what : String) (s : Conn.State σ) (d : Option Conn.Deadline) (gen : Nat) : Check Unit := do
  if s.phase.deadline != d then fail s!"{what}: deadline {repr s.phase.deadline}, want {repr d}"
  if s.gen != gen then fail s!"{what}: generation {s.gen}, want {gen}"

/-- An expiry of `d` in generation `g` that must change nothing. -/
def expectStale (what : String) (h : Server.Adapter σ) (s : Conn.State σ) (d : Conn.Deadline) (g : Nat) : Check Unit := do
  let (s', a) := Conn.step h 0 s (.expired d g)
  match a with
  | .none => pure ()
  | _ => fail s!"{what}: a stale expiry was acted on"
  if s'.phase.deadline != s.phase.deadline || s'.gen != s.gen || s'.buf != s.buf then
    fail s!"{what}: a stale expiry changed the state"

/-- The deadlines through `Conn.step` with H1 (item ytzycm): which deadline
each phase runs under, that a phase change starts a new generation and a
fragment of the same head, body or response keeps it, that an expiry of an
older generation or of another deadline changes nothing, and that the
current one closes, after which nothing is acted on. A pipelined request's
head budget runs from its first byte (item dv6ikn): beside the response's
write, as the next generation (`Phase.ahead`), from the receive that brought
it or from its arrival in the kernel (`Event.arrived`); the end of the
response keeps that pair, and its expiry during the write closes on a
partial head and ends the budget on a complete one. -/
def deadlineScenario : Check Unit := do
  let h := H1Adapter.adapter {} App.Fixture.app
  let s0 := Conn.initial h
  expectDeadline "deadlines: a new connection" s0 (some .head) 0
  expectClose "deadlines: the first head expires" (Conn.step h 0 s0 (.expired .head 0)).2
  expectStale "deadlines: another deadline" h s0 .idle 0
  expectStale "deadlines: a later generation" h s0 .head 1
  -- A head in two parts keeps its generation; the body starts a new one.
  let (s1, _) := Conn.step h 0 s0 (.received (bytes "POST /echo HTTP/1.1\r\nHo"))
  expectDeadline "deadlines: part of the head" s1 (some .head) 0
  let (s2, _) := Conn.step h 0 s1 (.received (bytes "st: a\r\nContent-Length: 5\r\n\r\nhe"))
  expectDeadline "deadlines: the head accepted" s2 (some .body) 1
  expectStale "deadlines: the head's expiry after the head" h s2 .head 0
  let (s3, _) := Conn.step h 0 s2 (.received (bytes "l"))
  expectDeadline "deadlines: part of the body" s3 (some .body) 1
  let (s4, a4) := Conn.step h 0 s3 (.received (bytes "lo"))
  let some (resp, _) ← expectSend "deadlines: the request" a4 | return
  expectDeadline "deadlines: the response" s4 (some .write) 2
  expectStale "deadlines: the body's expiry after the body" h s4 .body 1
  let (s5, _) := Conn.step h 0 s4 (.sent 3)
  expectDeadline "deadlines: part of the response" s5 (some .write) 2
  let (s6, a6) := Conn.step h 0 s5 (.sent (resp.size - 3))
  expectRecv "deadlines: after the response" a6 inCap
  expectDeadline "deadlines: keep-alive" s6 (some .idle) 3
  expectStale "deadlines: the response's expiry after it" h s6 .write 2
  let (s7, a7) := Conn.step h 0 s6 (.expired .idle 3)
  expectClose "deadlines: keep-alive expires" a7
  match (Conn.step h 0 s7 (.received (bytes "GET / HTTP/1.1\r\nHost: a\r\n\r\n"))).2,
      (Conn.step h 0 s7 (.expired .idle 3)).2 with
  | .none, .none => pure ()
  | _, _ => fail "deadlines: an event after the expiry was acted on"
  -- The next request's first byte ends keep-alive and starts its head.
  let (s8, _) := Conn.step h 0 s6 (.received (bytes "GET"))
  expectDeadline "deadlines: the next head" s8 (some .head) 4
  -- Pipelined: the head left over from the request's receive runs its budget
  -- beside the response, as generation 2; the reading after the response
  -- keeps that pair, so finishing the response neither starts nor resets it.
  let two := "GET / HTTP/1.1\r\nHost: a\r\n\r\nGET / HTTP/1.1\r\nHo"
  let (p1, pa1) := Conn.step h 0 s0 (.received (bytes two))
  let some (r1, _) ← expectSend "deadlines: pipelined" pa1 | return
  expectDeadline "deadlines: the first pipelined response" p1 (some .write) 1
  if p1.phase.ahead != some .head then fail "deadlines: no head budget beside the response"
  if p1.watches then fail "deadlines: watching with the next head's bytes in the buffer"
  let (p2, _) := Conn.step h 0 p1 (.sent r1.size)
  expectDeadline "deadlines: the pipelined head" p2 (some .head) 2
  -- Its expiry during the write closes: the head is partial.
  expectClose "deadlines: a partial pipelined head expires behind its response" (Conn.step h 0 p1 (.expired .head 2)).2
  expectStale "deadlines: an earlier head generation beside the response" h p1 .head 1
  expectStale "deadlines: a later head generation beside the response" h p1 .head 3
  match Conn.step h 0 p1 .arrived with
  | (p1', .none) =>
    if p1'.phase.ahead != some .head || p1'.gen != 1 || p1'.buf != p1.buf then
      fail "deadlines: an arrival with a head under way changed the state"
  | _ => fail "deadlines: an arrival with a head under way was acted on"
  -- Two complete requests whose responses are not one batch (the second
  -- closes the connection, item paarzq): the second response is a new write
  -- period.
  let (w1, wa1) := Conn.step h 0 s0 (.received (bytes "GET / HTTP/1.1\r\nHost: a\r\n\r\nGET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"))
  let some (q, _) ← expectSend "deadlines: two pipelined requests" wa1 | return
  expectDeadline "deadlines: the first of two responses" w1 (some .write) 1
  let (w2, wa2) := Conn.step h 0 w1 (.sent q.size)
  let some (_, off) ← expectSend "deadlines: the second response" wa2 | return
  if off != 0 then fail s!"deadlines: the second response starts at {off}"
  expectDeadline "deadlines: the second response" w2 (some .write) 2
  expectStale "deadlines: the first response's expiry after it" h w2 .write 1
  -- A complete pipelined head (its body incomplete, so not answered with the
  -- response before it) whose budget ends behind a slow response: the
  -- budget ends without a close, the response goes on, and the body is
  -- read after it.
  let (b1, ba1) := Conn.step h 0 s0 (.received (bytes "GET / HTTP/1.1\r\nHost: a\r\n\r\nPOST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhe"))
  let some (bq, _) ← expectSend "deadlines: a response before a complete head" ba1 | return
  if b1.phase.ahead != some .head then fail "deadlines: no head budget beside the response before a complete head"
  match Conn.step h 0 b1 (.expired .head 2) with
  | (b1', .none) =>
    expectDeadline "deadlines: a complete head's budget ended" b1' (some .write) 1
    if b1'.phase.ahead != none then fail "deadlines: a complete head's budget still runs"
    if b1'.buf != b1.buf then fail "deadlines: a complete head's expiry changed the buffer"
    let (b2, ba2) := Conn.step h 0 b1' (.sent bq.size)
    expectRecv "deadlines: the body after its head's budget" ba2 (inCap - b1.buf.size)
    expectDeadline "deadlines: the body after its head's budget" b2 (some .body) 2
  | _ => fail "deadlines: a complete pipelined head's expiry was acted on"
  -- A next request's byte that arrives in the kernel during the write starts
  -- its head budget then (no byte in the buffer: the loop watches).
  if !s4.watches then fail "deadlines: not watching for the next request during the response"
  if s4.phase.ahead != none then fail "deadlines: a head budget before any byte"
  let (k1, ka1) := Conn.step h 0 s4 .arrived
  match ka1 with
  | .none => pure ()
  | _ => fail "deadlines: an arrival was acted on"
  expectDeadline "deadlines: the response after an arrival" k1 (some .write) 2
  if k1.phase.ahead != some .head || k1.watches then fail "deadlines: an arrival did not start the head budget"
  let (k2, ka2) := Conn.step h 0 k1 (.sent resp.size)
  expectRecv "deadlines: after the response with an arrival" ka2 inCap
  expectDeadline "deadlines: the arrived head after the response" k2 (some .head) 3
  expectClose "deadlines: the arrived head expires behind its response" (Conn.step h 0 k1 (.expired .head 3)).2
  match Conn.step h 0 s6 .arrived with
  | (s6', .none) => expectDeadline "deadlines: an arrival while reading" s6' (some .idle) 3
  | _ => fail "deadlines: an arrival while reading was acted on"
  -- Expect continue: the interim response runs under the body's deadline,
  -- which the body keeps.
  let (c1, ca1) := Conn.step h 0 s0 (.received (bytes "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"))
  let some (interim, _) ← expectSend "deadlines: a head with Expect" ca1 | return
  expectDeadline "deadlines: the interim response" c1 (some .body) 1
  let (c2, _) := Conn.step h 0 c1 (.sent 2)
  expectDeadline "deadlines: part of the interim response" c2 (some .body) 1
  let (c3, _) := Conn.step h 0 c2 (.sent (interim.size - 2))
  expectDeadline "deadlines: the body after the interim response" c3 (some .body) 1
  expectClose "deadlines: the body expires after the interim response" (Conn.step h 0 c3 (.expired .body 1)).2
  -- A query runs under no deadline: every expiry while querying is stale.
  let hd := H1Adapter.adapter {} App.Db.app
  let (q1, _) := Conn.step hd 0 (Conn.initial hd) (.received (bytes "GET /db?id=1 HTTP/1.1\r\nHost: a\r\n\r\n"))
  expectDeadline "deadlines: querying" q1 none 1
  for d in [Conn.Deadline.idle, .head, .body, .write] do
    for g in [0, 1] do expectStale "deadlines: querying" hd q1 d g

def expectQuery (what : String) (a : Conn.Action) (sql : String) (params : Array (Option String)) : Check Unit :=
  match a with
  | .query q => if q.sql != sql || q.params != params then fail s!"{what}: asked {repr q.sql} {q.params}" else pure ()
  | _ => fail s!"{what}: did not ask for a query"

def statusLine (d : ByteArray) : String := ((String.fromUTF8! d).splitOn "\r\n").head!

/-- A handler that waits for queries, through `Conn.step` with H1: `/chain`
asks for a query, continues with its result to a second one built from it,
then sends the response; a request pipelined behind it waits in the buffer
(no receive while querying) and is answered in the same send. A lost connection
answers 503; a failure report while querying closes. -/
def queryScenario : Check Unit := do
  let h := H1Adapter.adapter {} App.Db.app
  let req := "GET /chain HTTP/1.1\r\nHost: a\r\n\r\n"
  let next := "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
  let (s1, a1) := Conn.step h 0 (Conn.initial h) (.received (bytes (req ++ next)))
  expectQuery "query: the first query" a1 "SELECT 1" #[]
  if s1.buf != bytes next then fail "query: the request was not consumed, or the pipelined one was"
  let (s2, a2) := Conn.step h 0 s1 (.answered (.rows #["?column?"] #[#[some "1"]]))
  expectQuery "query: the second query" a2 "SELECT $1::int + 1" #[some "1"]
  let (s3, a3) := Conn.step h 0 s2 (.answered (.rows #["?column?"] #[#[some "2"]]))
  -- The response and the pipelined request's, answered at once, are one send
  -- (item paarzq).
  let some (resp, _) ← expectSend "query: the response" a3 | return
  let some (alone, _) ← expectSend "query: the pipelined request alone"
    (Conn.step h 0 (Conn.initial h) (.received (bytes next))).2 | return
  let first := resp.extract 0 (resp.size - alone.size)
  let text := String.fromUTF8! first
  if statusLine resp != "HTTP/1.1 200 OK" || !text.endsWith "\r\n\r\n2" then fail s!"query: answered {repr text}"
  if resp.extract first.size resp.size != alone then fail "query: the pipelined request was not answered after the response"
  if s3.buf.size != 0 then fail "query: the pipelined request was not consumed"
  let (_, a4) := Conn.step h 0 s3 (.sent resp.size)
  expectRecv "query: after both responses" a4 inCap
  -- A lost connection: 503, and the connection goes on.
  let (s5, _) := Conn.step h 0 (Conn.initial h) (.received (bytes "GET /db?id=42 HTTP/1.1\r\nHost: a\r\n\r\n"))
  let (_, a6) := Conn.step h 0 s5 (.answered (.error "08006" "lost"))
  let some (resp3, _) ← expectSend "query: a lost connection" a6 | return
  if statusLine resp3 != "HTTP/1.1 503 Service Unavailable" then fail s!"query: a lost connection answered {statusLine resp3}"
  -- An abandoned query (its outcome unknown) reaches the handler as itself,
  -- at either query of `/chain`: 500 saying so, never a result.
  let (c1, _) := Conn.step h 0 (Conn.initial h) (.received (bytes req))
  let (c2, _) := Conn.step h 0 c1 (.answered (.rows #["?column?"] #[#[some "1"]]))
  for (what, s) in [("the first query", c1), ("the second query", c2)] do
    let (_, a) := Conn.step h 0 s (.answered (.abandoned "54000" "the result exceeds Query.maxResultBytes"))
    let some (r, _) ← expectSend s!"query: {what} abandoned" a | return
    if statusLine r != "HTTP/1.1 500 Internal Server Error" || !(String.fromUTF8! r).endsWith "\r\n\r\ndatabase error 54000, outcome unknown\n" then
      fail s!"query: {what} abandoned answered {repr (String.fromUTF8! r)}"
  expectClose "query: a failure while querying" (Conn.step h 0 s5 .failed).2
  -- An answer out of place (no query asked) closes.
  expectClose "query: an answer while reading" (Conn.step h 0 (Conn.initial h) (.answered (.rows #[] #[]))).2

/-- Clocks at which two responses (`Dated`) are compared: the epoch and the
widest Date (the year 9999). -/
def clocks : List Nat := [0, 253402300799]

def sameDated (a b : Dated) : Bool := clocks.all fun t => a t == b t

/-- The clock reaches a response only at the event that sends it, through one
adapter value: a request completed by its second receive carries that
receive's Date, not the first's, and so does a request pipelined behind it
whose response is sent with it (item paarzq); a pipelined request answered
only once the response before it is sent (here: it closes the connection)
carries that send's Date; a response that waited for a query carries the
answer's Date, not the receive's. -/
def clockScenario : Check Unit := do
  let h := H1Adapter.adapter {} App.Db.app
  let hasDate (what : String) (d : ByteArray) (t : Nat) : Check Unit := do
    let want := "\r\nDate: " ++ String.fromUTF8! (Response.pushDate ByteArray.empty t) ++ "\r\n"
    let text := String.fromUTF8! d
    if (text.splitOn want).length ≤ 1 then fail s!"clock: {what}: no {repr want} in {repr text}"
  let req := "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
  let (s1, a1) := Conn.step h 951782400 (Conn.initial h) (.received (bytes "GET / HTTP/1.1\r\nHo"))
  expectRecv "clock: the first part" a1 (inCap - 18)
  let closing := "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
  let (s2, a2) := Conn.step h 1767225599 s1 (.received (bytes ("st: a\r\n\r\n" ++ req ++ closing)))
  let some (r2, _) ← expectSend "clock: the completed request" a2 | return
  let date := "\r\nDate: " ++ String.fromUTF8! (Response.pushDate ByteArray.empty 1767225599) ++ "\r\n"
  if ((String.fromUTF8! r2).splitOn date).length != 3 then
    fail s!"clock: the completed request and the one pipelined with it do not both carry the receive's Date: {repr (String.fromUTF8! r2)}"
  let (_, a3) := Conn.step h 1793580020 s2 (.sent r2.size)
  let some (r3, _) ← expectSend "clock: the pipelined request" a3 | return
  hasDate "the send before a pipelined request" r3 1793580020
  let (s4, _) := Conn.step h 951782400 (Conn.initial h) (.received (bytes "GET /db?id=42 HTTP/1.1\r\nHost: a\r\n\r\n"))
  let (_, a5) := Conn.step h 1793580020 s4 (.answered (.error "08006" "lost"))
  let some (r5, _) ← expectSend "clock: the answered query" a5 | return
  hasDate "the query's answer" r5 1793580020

/-- Two continuations' first steps alike: the same response, or the same query. -/
def sameStep : Await Dated → Await Dated → Bool
  | .done a, .done b => sameDated a b
  | .query q _, .query r _ => q.sql == r.sql && q.params == r.params
  | _, _ => false

/-- Two answers alike: the same kind, bytes consumed and response bytes; a
query's continuation is a function, compared by the query it asks and by its
first step on a row, on no rows, on an error and on an abandoned query. -/
def sameReply : Reply → Reply → Bool
  | .needMore a, .needMore b => a == b
  | .continue a, .continue b => a == b
  | .respond n a, .respond m b => n == m && sameDated a b
  | .await n q k, .await m r l =>
    n == m && q.sql == r.sql && q.params == r.params &&
      [Query.Result.rows #["id", "randomnumber"] #[#[some "42", some "7"]], .rows #[] #[], .error "08006" "lost", .abandoned "54000" "over"].all
        fun res => sameStep (k res) (l res)
  | _, _ => false

/-- The adapter's law (`Adapter.Incremental`): `b` fed in pieces of `k` bytes,
each call with the state the previous one kept while its answer waited (as
`Conn` does), answers every prefix as one call from the initial state does. -/
def lawFor (ad : Adapter) (app : Handler) (what : String) (b : ByteArray) (k : Nat) : Check Unit := do
  let a := ad.make {} app
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

/-- The corpus `lsrv-bench` measures: the two parsers consume the same bytes
of each sequence, and each request of its fragmentation table, fed to a new
connection through `Conn.step` in receives of 1, 7, 64 and 1460 bytes, is
answered after its last receive with the nonempty response it gets in one
receive. The HttpArena shapes and the full-buffer cases `lsrv-parsebench`
measures pass `Corpus.arenaShapesCheck` and `Corpus.fullCasesCheck`. -/
def corpusScenario : Check Unit := do
  for (name, req) in Corpus.requests do
    let b := bytes req
    if Corpus.handParse b != Corpus.h1Parse b then
      fail s!"corpus {name}: hand-written consumes {Corpus.handParse b}, H1 {Corpus.h1Parse b}"
  for ad in [h1, hand] do
    let a := ad.make {} App.Hello.app
    for (name, req) in Corpus.fragmentCorpus do
      let b := bytes req
      let some whole := Corpus.fragmented a b.size b
        | fail s!"corpus {ad.name} {name}: no response in one receive"
      if whole.size == 0 then fail s!"corpus {ad.name} {name}: an empty response in one receive"
      for k in [1, 7, 64, 1460] do
        match Corpus.fragmented a k b with
        | none => fail s!"corpus {ad.name} {name} in receives of {k} B: no response after the last receive"
        | some d => if d != whole then fail s!"corpus {ad.name} {name} in receives of {k} B: another response than in one receive"
  -- The shapes `lsrv-parsebench` measures.
  if let some e := Corpus.arenaShapesCheck then fail s!"arena shapes: {e}"
  if let some e := Corpus.fullCasesCheck then fail s!"full-buffer cases: {e}"

def lawCases (ad : Adapter) : Check Unit := do
  for c in cases do
    let b := bytes c.request
    for k in [1, 2, 3, 7, 64] do lawFor ad c.app c.name b k
    -- Every split in two (the second call extends the first's buffer).
    for i in [1:b.size] do
      if b.size ≤ 600 then
        let a := ad.make {} c.app
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
    let r := ad.handle {} c.app (bytes c.request)
    let (kind, status) := if ad.name == hand.name then c.hand.getD (c.kind, c.status) else (c.kind, c.status)
    let want := c.consumes.getD (if kind == 0 then 0 else (bytes c.request).size)
    if resultKind r != kind || statusOf r != status || consumed r != want then
      fail s!"{ad.name} {c.name}: kind {resultKind r} status {statusOf r} consumed {consumed r}; want kind {kind} status {status} consumed {want}"
  for req in framed do
    let b := bytes req
    for k in [0:b.size] do
      if resultKind (ad.handle {} App.Hello.app (b.extract 0 k)) != 0 then
        fail s!"{ad.name} prefix {k} of {repr req} did not ask for more bytes"
  -- HEAD: the GET's Content-Length, no body.
  let r := responseOf (ad.handle {} App.Hello.app (bytes "HEAD / HTTP/1.1\r\nHost: a\r\n\r\n"))
  if !r.endsWith "\r\nContent-Length: 13\r\n\r\n" then fail s!"{ad.name} HEAD: {repr r}"

/-! ## HttpArena's endpoints (`App.Arena`, item 53rwgc) -/

/-- HttpArena's request templates (`requests/get.raw`, `post_cl.raw`,
`pipeline.raw` at da3ded60952b) and its validation's other values, through
H1: each answers 200 with go-stdlib's body and `text/plain`. Its chunked
template (`post_chunked.raw`) gets 501, the server's contract while chunked
request bodies are not decoded (docs/production-contract.md, "Not yet"); the runs leave it out. -/
def arenaScenario : Check Unit := do
  let h := "Host: localhost:8080\r\n"
  let ok : List (String × String × String) := [
    ("get.raw", s!"GET /baseline11?a=13&b=42 HTTP/1.1\r\n{h}\r\n", "55"),
    ("post_cl.raw", s!"POST /baseline11?a=13&b=42 HTTP/1.1\r\n{h}Content-Length: 2\r\n\r\n20", "75"),
    ("pipeline.raw", s!"GET /pipeline HTTP/1.1\r\n{h}\r\n", "ok"),
    -- Go decodes `+` in a query to a space, which Atoi refuses; a body is not decoded.
    ("negative and signed values", s!"POST /baseline11?a=-7&b=+3&c=4 HTTP/1.1\r\n{h}Content-Length: 2\r\n\r\n+5", "2"),
    ("a value is everything after the first =", s!"GET /baseline11?a=1=2&b=3 HTTP/1.1\r\n{h}\r\n", "3"),
    ("non-integers count nothing", s!"POST /baseline11?a=x&b=2&c HTTP/1.1\r\n{h}Content-Length: 3\r\n\r\n1.5", "2"),
    ("body with whitespace", s!"POST /baseline11?a=1 HTTP/1.1\r\n{h}Content-Length: 4\r\n\r\n 9\r\n", "10"),
    ("no query", s!"GET /baseline11 HTTP/1.1\r\n{h}\r\n", "0"),
    -- Go's int on x86_64: the sum wraps, a value beyond 64 bits counts nothing.
    ("the sum wraps at 64 bits", s!"GET /baseline11?a=9000000000000000000&b=9000000000000000000 HTTP/1.1\r\n{h}\r\n", "-446744073709551616"),
    ("64-bit bounds", s!"GET /baseline11?a=-9223372036854775808&b=9223372036854775807&c=9223372036854775808 HTTP/1.1\r\n{h}\r\n", "-1")]
  for (name, req, body) in ok do
    let r := responseOf (ad1 req)
    if !r.startsWith "HTTP/1.1 200 OK\r\n" || !r.contains "\r\nContent-Type: text/plain\r\n" || !r.endsWith s!"\r\n\r\n{body}" then
      fail s!"arena {name}: {repr r}, want 200 text/plain {body}"
  let chunked := s!"POST /baseline11?a=13&b=42 HTTP/1.1\r\n{h}Transfer-Encoding: chunked\r\n\r\n2\r\n20\r\n0\r\n\r\n"
  for (name, req, status) in [("post_chunked.raw", chunked, "HTTP/1.1 501 Not Implemented"),
      ("unknown path", s!"GET /baseline12 HTTP/1.1\r\n{h}\r\n", "HTTP/1.1 404 Not Found"),
      ("PUT", s!"PUT /baseline11 HTTP/1.1\r\n{h}Content-Length: 0\r\n\r\n", "HTTP/1.1 404 Not Found")] do
    let r := ad1 req
    if statusOf r != status then fail s!"arena {name}: {statusOf r}, want {status}"
where
  ad1 (req : String) : Reply := h1.handle {} App.Arena.app (bytes req)

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
    let r0 := responseOf (ad.handle {} c.app (bytes c.request))
    let r1 := responseOf (ad.handle own c.app (bytes c.request))
    let status := ((statusOf (ad.handle {} c.app (bytes c.request))).splitOn " ")[1]?.getD ""
    let want := if ownStatuses.contains status then r0.replace ct (ct ++ lines) else r0
    if ownStatuses.contains status && !r0.contains ct then fail s!"{ad.name} {c.name}: no Content-Type in {repr r0}"
    if r1 != want then fail s!"{ad.name} own fields, {c.name}: {repr r1}, want {repr want}"
  -- The status does not decide: the application's own 400, 500 and 501 carry no own fields.
  for status in [400, 500, 501] do
    let app : Handler := fun _ => .done { status, headers := #[Response.contentType], body := "x".toUTF8 }
    let req := bytes "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
    let r0 := responseOf (ad.handle {} app req)
    let r1 := responseOf (ad.handle own app req)
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

/-! ## The H1 adapter's retained state

The bound docs/memory.md derives for what `H1Adapter.Parser` holds while a
request is incomplete, by part, in bytes of allocator blocks (toolchain
nightly-2026-11-19, mimalloc 3.4.5 `mi_good_size`), and the check that the
blocks the state actually holds stay within each part on requests that drive
each part to its largest. -/

/-- The bytes of the allocator blocks `x` holds, each block once, persistent
(shared, initialization-time) objects left out: `test/retained.c`. -/
@[extern "lsrv_retained_bytes"] opaque retainedBytes {α : Type} (x : @& α) : Nat

/-- The machine's input: at most `inCap` bytes, with capacity at most twice
that (an append that runs out doubles the size it needs), a 40,960-byte block,
and the iterator's 24-byte constructor. -/
def inputBound : Nat := 40960 + 24
/-- The body pulled so far: under `maxBodyBytes`, capacity at most twice. -/
def bodyBound : Nat := 20480
/-- A block holding an object of `x` bytes: at most `x + x/4 + 7`. -/
def block (x : Nat) : Nat := x + x / 4 + 7

/-- The parsed request-target, whose element counts `H1Adapter.config` limits.
A path segment is a `ByteArray` of its bytes (24-byte header, capacity its
size), so a block of at most 37 bytes plus 5/4 of its bytes; a query parameter
is a 24-byte pair of its key and, if it has `=`, a 16-byte `some` of its value,
each such a `ByteArray`: at most 114 plus 5/4 of its bytes, since the pair and
the `some` take blocks of exactly their size (`mi_good_size` of 16 and 24 is
16 and 24, as of every multiple of 8 up to 64, measured against the
toolchain's `libleanshared`). The other parts of
an absolute-form target (scheme, user name, password, host, fragment) are at
most five strings (32-byte header, its bytes and NUL): at most 49 each plus
5/4 of their bytes. The bytes of all of them together are at most
`maxUriLength`. The arrays of segments and parameters have capacity at most
twice their size, 8 bytes per slot after a 24-byte header; 512 for the
target's own constructors (target, URI, path, authority, user info, port,
host and the `some`s around them). -/
def targetBound : Nat :=
  37 * H1Adapter.maxPathSegments + 114 * H1Adapter.maxQueryParams + 5 * 49
    + (5 * H1Adapter.config.maxUriLength) / 4
    + block (24 + 16 * H1Adapter.maxPathSegments) + block (24 + 16 * H1Adapter.maxQueryParams) + 512
/-- The header fields: at most `maxHeaders` pairs (24 bytes each) in an array
of capacity 126 (1,280 bytes), a 16-byte wrapper, and a name and a value
string each, whose bytes total at most `maxHeadBytes`; a string is a 32-byte
header and its bytes and NUL, with capacity at most twice that, and a block
of `x` bytes is at most `x + x/4 + 7`. -/
def headersBound : Nat :=
  let strings := 2 * maxHeaders
  24 * maxHeaders + 1280 + 16 + (5 * (strings * 34 + 2 * maxHeadBytes)) / 4 + 7 * strings
/-- The constructors of the parser, machine, reader and its state, writer and
message head. -/
def fixedBound : Nat := 1024
def adapterBound : Nat := inputBound + bodyBound + targetBound + headersBound + fixedBound

/-- `s` repeated `n` times. -/
def rep (s : String) (n : Nat) : String := String.join (List.replicate n s)

/-- Requests whose incomplete states drive a part of the adapter's state to
its largest; each ends incomplete. A target is kept from the end of its
request line, so the longest the line allows (8,192 bytes with CRLF), with
the most elements the limits allow, is followed by nothing; fields and a body
follow a short line. -/
def retainedRequests : List (String × String) :=
  let line (target : String) := s!"GET {target} HTTP/1.1\r\n"
  -- The longest target the line allows: the rest of `maxHeadBytes` after
  -- "GET ", SP, "HTTP/1.1" and CRLF.
  let room := maxHeadBytes - (line "").length
  -- `pre`, then what the line leaves to one element, in `c`s.
  let fill (pre c : String) := pre ++ rep c (room - pre.length)
  let (ns, np) := (H1Adapter.maxPathSegments, H1Adapter.maxQueryParams)
  let segs := rep "/" ns
  let params := rep "=&" (np - 1)
  let longValue := rep "v" 64
  let longFields := String.join ((List.range 96).map fun i => s!"x{i}: {longValue}\r\n")
  [(s!"{ns} empty segments and {np} parameters, {np - 1} with empty values, the rest in the last value",
     line (fill s!"{segs}?{params}=" "v")),
   (s!"{np} query parameters, {np - 1} empty, the rest in the last key",
     line (fill s!"/?{rep "&" (np - 1)}" "k")),
   (s!"{ns} path segments, {ns - 1} empty, the rest in the last", line (fill segs "s")),
   (s!"an absolute-form target with {ns} segments and {np} parameters",
     line (fill s!"http://a{segs}?{params}=" "v")),
   (s!"an absolute-form target with user info, a port, {ns} segments and {np} parameters",
     line (fill s!"http://u:p@a:80{segs}?{params}=" "v")),
   (s!"{maxHeaders} fields", s!"POST / HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 10\r\n{String.join ((List.range (maxHeaders - 3)).map fun i => s!"x{i}:\r\n")}\r\n"),
   ("all but one byte of a maximum body after 96 long fields",
     s!"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: {maxBodyBytes}\r\n{longFields}\r\n{rep "b" (maxBodyBytes - 1)}")]

/-- Feeds each request whole and in pieces of 7 and 1,460 bytes, keeping the
state as the connection does, and checks every state kept while the request
waits against each part's bound and the whole. -/
def retainedScenario : Check Unit := do
  for (name, req) in retainedRequests do
    let b := bytes req
    for k in [b.size, 7, 1460] do
      let mut p : H1Adapter.Parser := {}
      let mut n := 0
      let mut largest := 0
      let mut last : H1Adapter.Parsed := .needMore .head
      while n < b.size do
        n := min b.size (n + k)
        (p, last) := p.parse (b.extract 0 n)
        match last with
        | .needMore _ | .awaitingBody =>
          let head := p.machine.reader.messageHead
          let parts := [("input", retainedBytes p.machine.reader.input, inputBound),
            ("body", retainedBytes p.body, bodyBound), ("target", retainedBytes head.uri, targetBound),
            ("headers", retainedBytes head.headers, headersBound), ("whole", retainedBytes p, adapterBound)]
          for (part, got, bound) in parts do
            if got > bound then fail s!"retained state, {name}, pieces of {k}, {n} bytes: {part} {got} > {bound}"
          largest := max largest (retainedBytes p)
        | _ => fail s!"retained state, {name}, pieces of {k}: answered at {n} of {b.size} bytes"
      if k == b.size then IO.println s!"retained state, {name} ({b.size} bytes): at most {largest} of {adapterBound} bytes"

/-! ## A written response's capacity -/

/-- The capacity of `a`: `test/retained.c`. -/
@[extern "lsrv_byte_array_capacity"] opaque byteArrayCapacity (a : @& ByteArray) : Nat

/-- The response's bytes spelled out independently of `Response.write`. -/
def expectedWrite (now : Nat) (r : Response) (close headOnly : Bool) : ByteArray :=
  let fields := String.join (r.headers.toList.map fun (n, v) => s!"{n}: {v}\r\n")
  let date := String.fromUTF8! (Response.pushDate ByteArray.empty now)
  let cl := if Response.noBody r.status then "" else s!"\r\nContent-Length: {r.body.size}"
  let conn := if close then "\r\nConnection: close" else ""
  let head := s!"HTTP/1.1 {r.status} {Response.reason r.status}\r\n{fields}Date: {date}{cl}{conn}\r\n\r\n"
  head.toUTF8 ++ (if headOnly || Response.noBody r.status then ByteArray.empty else r.body)

/-- `Response.write` gives an array whose capacity is its size, with heads
shorter and longer than the scratch 192 bytes and responses of exactly
`maxResponseBytes`, bytes as `expectedWrite` spells them; a response at the
limit is one 81,920-byte block (docs/memory.md). -/
def responseCapacityScenario : Check Unit := do
  let now := 253402300799
  for (what, fs) in [("a short head", #[Response.contentType]),
      ("a head over 192 bytes", #[Response.contentType, ("X-Long", fill 'a' 1 300)]),
      ("a head of 40,000 bytes", #[Response.contentType, ("X-Long", fill 'a' 1 40000)])] do
    for close in [false, true] do
      let headSize := (Response.write now { status := 200, headers := fs } close true).size
      -- A body of 1 byte makes Content-Length one digit; the limit's body, five.
      let atLimit := maxResponseBytes - (headSize + 4)
      -- 204 and 304 are written without their body (`check` rejects one first).
      for (status, body) in [(200, ByteArray.empty), (200, "x".toUTF8),
          (200, ByteArray.mk (Array.replicate atLimit 98)), (204, ByteArray.empty),
          (204, "x".toUTF8), (304, ByteArray.empty), (304, "x".toUTF8)] do
        for headOnly in [false, true] do
          let r : Response := { status, headers := fs, body }
          let out := Response.write now r close headOnly
          let cap := byteArrayCapacity out
          if out != expectedWrite now r close headOnly then
            fail s!"response capacity, {what}, {status} body {body.size} close {close} head {headOnly}: bytes differ"
          if cap != out.size then
            fail s!"response capacity, {what}, {status} body {body.size} close {close} head {headOnly}: capacity {cap} for {out.size} bytes"
          if body.size == atLimit && !headOnly then
            if out.size != maxResponseBytes then fail s!"response capacity, {what}, close {close}: {out.size} bytes at the limit"
            if retainedBytes out != 81920 then
              fail s!"response capacity, {what}, close {close}: a {retainedBytes out}-byte block at the limit, want 81,920"

/-! ## A receive appends in place (item l46evh) -/

/-- The address of `a`'s bytes, as an integer: `test/retained.c`. -/
@[extern "lsrv_byte_array_address"] opaque byteArrayAddress (a : @& ByteArray) : Nat

/-- A receive that leaves the request incomplete appends to the buffer in
place: `Conn.step` holds no reference to the state while `advance` answers a
receive, so a buffer the connection holds alone, with room for the bytes,
keeps its address. The first receive copies the buffer of `Conn.initial`,
which every connection shares (a closed term), into one of capacity `inCap`
that the connection holds alone; each receive after it must keep that
address: 150 of 7 bytes of a head field, the head's end, then 150 of 7 bytes
of the body. A `step` that reads the state after `advance` (as from 69c915a,
docs/reports/chunked-receive-memory.md) copies the buffer on every receive
and fails this at the first receive after the first. -/
def receiveInPlaceScenario (ad : Adapter) : Check Unit := do
  let h := ad.make {} App.Hello.app
  let name := s!"receive in place, {ad.name}"
  let start := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4000\r\nX: "
  let (s1, a1) := Conn.step h 0 (Conn.initial h) (.received (bytes start))
  expectRecv s!"{name}: after the head's start" a1 (inCap - s1.buf.size)
  let cap := byteArrayCapacity s1.buf
  if cap != inCap then fail s!"{name}: a buffer of capacity {cap} after the first receive, want {inCap}"
  let addr := byteArrayAddress s1.buf
  let pieces := List.replicate 150 "aaaaaaa" ++ ["\r\n\r\n"] ++ List.replicate 150 "bbbbbbb"
  let mut s := s1
  let mut i := 0
  for piece in pieces do
    i := i + 1
    let (s', a) := Conn.step h 0 s (.received (bytes piece))
    expectRecv s!"{name}: after receive {i + 1}" a (inCap - s'.buf.size)
    let got := byteArrayAddress s'.buf
    s := s'
    if got != addr then
      fail s!"{name}: receive {i + 1} moved the buffer, so it was copied rather than appended in place"
      return
  let want := start.length + 150 * 7 + 4 + 150 * 7
  if s.buf.size != want then fail s!"{name}: {s.buf.size} bytes buffered after the last receive, want {want}"
  match s.phase with
  | .reading (.body _) => pure ()
  | _ => fail s!"{name}: not reading the body after the last receive"

/-! ## Pipelined responses in one send (item paarzq) -/

/-- The response a new connection sends for `req` alone, or `none`. -/
def aloneResponse (h : Server.Adapter σ) (req : String) : Option ByteArray :=
  match (Conn.step h 0 (Conn.initial h) (.received (bytes req))).2 with
  | .send d 0 => some d
  | _ => none

/-- Drives a connection from state `s` and its action `a`, reporting each send
as written in pieces of at most `k` bytes, until it asks for anything but a
send. Fails unless every piece after the first of a send is asked for at the
offset where the last ended, of the same data, in the same deadline period.
The data of each send (once), and the state and action it ends with. -/
def drain (what : String) (h : Server.Adapter σ) (k : Nat) (s : Conn.State σ) (a : Conn.Action) :
    Check (Array ByteArray × Conn.State σ × Conn.Action) := do
  let mut s := s
  let mut a := a
  let mut sends := #[]
  -- Each step writes at least one byte, and no scenario sends a megabyte.
  for _ in [0:1000000] do
    match a with
    | .send d off =>
      if off == 0 then sends := sends.push d
      let n := min k (d.size - off)
      let (s', a') := Conn.step h 0 s (.sent n)
      if off + n < d.size then
        match a' with
        | .send d' off' =>
          if d' != d || off' != off + n || s'.gen != s.gen then
            fail s!"{what}: a partial send at {off + n} of {d.size} did not continue the same send"
            return (sends, s', a')
        | _ =>
          fail s!"{what}: a partial send at {off + n} of {d.size} did not continue"
          return (sends, s', a')
      s := s'
      a := a'
    | _ => return (sends, s, a)
  fail s!"{what}: did not stop sending"
  return (sends, s, a)

/-- The responses to the complete requests in the buffer, answered at once,
go out as one send (`Conn.batch`; one `send` action, which the transport
copies out in pieces of at most 8,192 bytes, its `out_cap`, so a batch of at
most that size is one system call when the kernel takes it whole, and the
head budget of a request behind it runs beside it as beside a single
response): in request order, the same bytes as each
request gets alone, across partial sends of any size, in an array whose
capacity is its size, never over `maxResponseBytes` (a batch at exactly the
bound is taken, one byte over is not) or `Conn.maxBatchRequests` responses,
and without a receive until every complete request in the buffer is
answered (backpressure: a buffer filled with requests is answered in sends
within both bounds before the connection reads again; the requests behind
a batch are served when its send completes). A batch stops before a request that is incomplete,
asks for `100 Continue` or a query, or closes the connection; that one is
served once the batch is sent, as before. -/
def batchScenario : Check Unit := do
  let h := H1Adapter.adapter {} App.Hello.app
  let get := "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
  let miss := "GET /nope HTTP/1.1\r\nHost: a\r\n\r\n"
  let some rGet := aloneResponse h get | fail "batch: GET / alone was not answered"; return
  let some rMiss := aloneResponse h miss | fail "batch: GET /nope alone was not answered"; return
  if rGet == rMiss then fail "batch: the two requests get the same response"
  -- Order, in one send, across partial sends.
  let reqs := (List.range 16).map fun i => if i % 2 == 0 then get else miss
  let want := ((List.range 16).map fun i => if i % 2 == 0 then rGet else rMiss).foldl (· ++ ·) ByteArray.empty
  let (s1, a1) := Conn.step h 0 (Conn.initial h) (.received (bytes (String.join reqs)))
  expectDeadline "batch: 16 pipelined requests" s1 (some .write) 1
  if s1.buf.size != 0 || !s1.watches then fail "batch: 16 pipelined requests were not all consumed"
  if let .send d _ := a1 then
    if byteArrayCapacity d != d.size then fail s!"batch: capacity {byteArrayCapacity d} for {d.size} bytes"
  for k in [want.size, 8192, 7, 1] do
    let (sends, s2, a2) ← drain s!"batch: 16 pipelined requests in pieces of {k}" h k s1 a1
    if sends != #[want] then fail s!"batch: 16 pipelined requests in pieces of {k}: {sends.size} sends, not their responses in order"
    expectRecv s!"batch: after 16 pipelined responses in pieces of {k}" a2 inCap
    expectDeadline s!"batch: after 16 pipelined responses in pieces of {k}" s2 (some .idle) 2
  -- The request bound (item umtm4l): of `maxBatchRequests` + 5 complete
  -- requests one step answers `maxBatchRequests`; the rest stay buffered,
  -- the next one's head budget beside the send, and the send's completion
  -- alone starts their batch: no receive and no arrival between.
  let over := Conn.maxBatchRequests + 5
  let rep (n : Nat) (r : ByteArray) := (List.replicate n r).foldl (· ++ ·) ByteArray.empty
  let (o1, oa1) := Conn.step h 0 (Conn.initial h) (.received (bytes (String.join (List.replicate over get))))
  match oa1 with
  | .send d 0 =>
    if d != rep Conn.maxBatchRequests rGet then fail s!"batch: {over} requests: the first send is not {Conn.maxBatchRequests} responses"
    if o1.buf != bytes (String.join (List.replicate 5 get)) || o1.phase.ahead != some .head then
      fail s!"batch: {over} requests: the 5 behind the bound are not buffered with a head budget beside the send"
    match Conn.step h 0 o1 (.sent d.size) with
    | (o2, .send d2 0) =>
      if d2 != rep 5 rGet || o2.buf.size != 0 then fail s!"batch: {over} requests: the second send is not the 5 responses left"
      expectDeadline s!"batch: {over} requests, the second send" o2 (some .write) 2
      expectRecv s!"batch: {over} requests, after the second send" (Conn.step h 0 o2 (.sent d2.size)).2 inCap
    | _ => fail s!"batch: {over} requests: the first send's completion did not start the second"
    -- The head budget beside the first send ends on the complete head behind
    -- the bound, and the send goes on.
    match Conn.step h 0 o1 (.expired .head 2) with
    | (oe, .none) =>
      if oe.phase.ahead != none || oe.buf != o1.buf then fail s!"batch: {over} requests: the head budget beside the bounded batch did not end"
      -- The send goes on: its completion still starts the batch of the rest.
      let stillSending := match oe.phase, oa1 with
        | .writing out 0 _, .send d 0 => out == d
        | _, _ => false
      unless stillSending do fail s!"batch: {over} requests: the bounded batch's send did not survive the head budget's expiry"
      match Conn.step h 0 oe (.sent (rep Conn.maxBatchRequests rGet).size) with
      | (_, .send d2 0) => if d2 != rep 5 rGet then fail s!"batch: {over} requests: after the head budget's expiry, the second send is not the 5 responses left"
      | _ => fail s!"batch: {over} requests: after the head budget's expiry, the first send's completion did not start the second"
    | _ => fail s!"batch: {over} requests: the expiry of a complete head behind the bounded batch was acted on"
  | _ => fail s!"batch: {over} requests: the receive was not answered with a send"
  -- An incomplete request behind the batch waits, its head budget beside it.
  let tail := "GET / HTTP/1.1\r\nHo"
  let (t1, ta1) := Conn.step h 0 (Conn.initial h) (.received (bytes (get ++ miss ++ tail)))
  if t1.buf != bytes tail || t1.phase.ahead != some .head then fail "batch: an incomplete request behind the batch"
  let (ts, t2, ta2) ← drain "batch: an incomplete request behind the batch" h 8192 t1 ta1
  if ts != #[rGet ++ rMiss] then fail "batch: the responses before an incomplete request"
  expectRecv "batch: an incomplete request behind the batch" ta2 (inCap - tail.length)
  expectDeadline "batch: an incomplete request behind the batch" t2 (some .head) 2
  -- A request that closes the connection ends the batch before it.
  let closing := "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
  let some rClose := aloneResponse h closing | fail "batch: a closing request alone"; return
  let (c1, ca1) := Conn.step h 0 (Conn.initial h) (.received (bytes (get ++ get ++ closing ++ get)))
  let (cs, _, ca2) ← drain "batch: a closing request" h 8192 c1 ca1
  if cs != #[rGet ++ rGet, rClose] then fail s!"batch: a closing request: {cs.size} sends, not two responses, then the closing one"
  expectClose "batch: after the closing response" ca2
  -- The head budget beside a partly sent batch (`Phase.ahead`, generation
  -- 2): its expiry closes on an incomplete head, and on a complete one left
  -- behind the batch ends the budget while the batch goes on from its offset.
  let (tp, tpa) := Conn.step h 0 t1 (.sent 5)
  let tpSending := match tpa with
    | .send d 5 => d == rGet ++ rMiss
    | _ => false
  unless tpSending && tp.phase.ahead == some .head do
    fail "batch: a batch with an incomplete head behind it, partly sent, is not still sending beside the head budget"
  expectClose "batch: an incomplete head's budget beside a partly sent batch" (Conn.step h 0 tp (.expired .head 2)).2
  let (cp, cpa) := Conn.step h 0 c1 (.sent 5)
  if cp.phase.ahead != some .head then fail "batch: a partly sent batch with a complete head behind it has no head budget"
  match Conn.step h 0 cp (.expired .head 2) with
  | (ce, .none) =>
    if ce.phase.ahead != none || ce.gen != 1 then fail "batch: a complete head's budget beside a partly sent batch did not end"
    match cpa with
    | .send d 5 =>
      if d != rGet ++ rGet then fail "batch: the partly sent batch is another one"
      -- The expiry kept the offset: one more byte continues at 6.
      let (c6, ca6) := Conn.step h 0 ce (.sent 1)
      let at6 := match ca6 with
        | .send d' 6 => d' == d
        | _ => false
      unless at6 do fail "batch: after a complete head's budget ended, the batch did not continue at offset 6"
      let (cs2, _, ca3) ← drain "batch: a complete head's budget ended beside a batch" h 8192 c6 ca6
      if cs2 != #[rClose] then fail "batch: after a complete head's budget ended beside a batch: not the closing response"
      expectClose "batch: after a complete head's budget ended beside a batch" ca3
    | _ => fail "batch: a partly sent batch did not continue at offset 5"
  | _ => fail "batch: a complete head's expiry beside a partly sent batch was acted on"
  -- `100 Continue` ends the batch before its request.
  let expect := "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"
  let (e1, ea1) := Conn.step h 0 (Conn.initial h) (.received (bytes (get ++ expect)))
  let (es, _, ea2) ← drain "batch: 100-continue" h 8192 e1 ea1
  if es != #[rGet, Response.continueBytes] then fail s!"batch: 100-continue: {es.size} sends, not the response, then the interim one"
  expectRecv "batch: the body after the interim response" ea2 (inCap - expect.length)
  -- A query ends the batch before its request.
  let hd := H1Adapter.adapter {} App.Db.app
  let some rDb := aloneResponse hd get | fail "batch: GET / of the database application alone"; return
  let (q1, qa1) := Conn.step hd 0 (Conn.initial hd) (.received (bytes (get ++ get ++ "GET /db?id=1 HTTP/1.1\r\nHost: a\r\n\r\n" ++ get)))
  let (qs, q2, qa2) ← drain "batch: a query" hd 8192 q1 qa1
  if qs != #[rDb ++ rDb] then fail "batch: a query: not the two responses before it"
  expectQuery "batch: the query after the batch" qa2 "SELECT id, randomnumber FROM world WHERE id = $1" #[some "1"]
  if q2.buf != bytes get then fail "batch: the request after the query was consumed"
  -- The bound: a batch of exactly `maxResponseBytes` is one send, held in
  -- one 81,920-byte block (docs/memory.md); a byte more is two sends.
  let hf := H1Adapter.adapter {} App.Fixture.app
  let echo (n : Nat) := s!"POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: {n}\r\n\r\n" ++ big n
  let some rBig := aloneResponse hf get | fail "batch: the fixture's GET / alone"; return
  let room := maxResponseBytes - rBig.size
  let some n := (List.range room).find? fun n => ((aloneResponse hf (echo n)).map (·.size)) == some room
    | fail s!"batch: no echo response of {room} bytes"; return
  for (m, sends) in [(n, 1), (n + 1, 2)] do
    let some rEcho := aloneResponse hf (echo m) | fail s!"batch: an echo of {m} bytes alone"; return
    let (b1, ba1) := Conn.step hf 0 (Conn.initial hf) (.received (bytes (get ++ echo m)))
    let (bs, _, ba2) ← drain s!"batch: {rBig.size} + {rEcho.size} bytes" hf 8192 b1 ba1
    if bs.size != sends || bs.foldl (· ++ ·) ByteArray.empty != rBig ++ rEcho then
      fail s!"batch: {rBig.size} + {rEcho.size} bytes: {bs.size} sends, want {sends}, of both responses in order"
    expectRecv s!"batch: after {rBig.size} + {rEcho.size} bytes" ba2 inCap
    if sends == 1 then
      if let .send d _ := ba1 then
        if d.size != maxResponseBytes || byteArrayCapacity d != d.size || retainedBytes d != 81920 then
          fail s!"batch at the bound: {d.size} bytes, capacity {byteArrayCapacity d}, a {retainedBytes d}-byte block"
  -- Backpressure: a buffer filled with requests is answered in sends of at
  -- most `maxResponseBytes`, all before the next receive.
  let many := inCap / get.length
  let (f1, fa1) := Conn.step h 0 (Conn.initial h) (.received (bytes (String.join (List.replicate many get))))
  let (fs, f2, fa2) ← drain "batch: a full buffer" h 8192 f1 fa1
  if fs.foldl (· ++ ·) ByteArray.empty != (List.replicate many rGet).foldl (· ++ ·) ByteArray.empty then
    fail s!"batch: a full buffer of {many} requests: not their responses in order"
  if fs.size < 2 || fs.any (·.size > min maxResponseBytes (Conn.maxBatchRequests * rGet.size)) then
    fail s!"batch: a full buffer of {many} requests: {fs.size} sends of {fs.map (·.size)} bytes"
  expectRecv "batch: after a full buffer" fa2 inCap
  if f2.buf.size != 0 then fail "batch: a full buffer was not consumed"

/-- An adapter whose requests are one byte each, all answered at once and
keeping the connection open, for the stops of `Conn.gather` and
`Conn.batch` that `H1Adapter` cannot produce: `Z` consumes no byte, `O` one
byte more than is buffered, `E` answers an empty response, `B` one of
`maxResponseBytes + 1` bytes; any other byte answers itself. An empty
buffer needs more of the head. -/
def oneByte : Server.Adapter Unit where
  init := ()
  handle _ buf := ((), match buf[0]? with
    | none => .needMore .head
    | some c =>
      if c == 'Z'.toUInt8 then .respond 0 fun _ => (ByteArray.mk #[c], false)
      else if c == 'O'.toUInt8 then .respond (buf.size + 1) fun _ => (ByteArray.mk #[c], false)
      else if c == 'E'.toUInt8 then .respond 1 fun _ => (ByteArray.empty, false)
      else if c == 'B'.toUInt8 then .respond 1 fun _ => (ByteArray.mk (Array.replicate (maxResponseBytes + 1) c), false)
      else .respond 1 fun _ => (ByteArray.mk #[c], false))

/-- The edges of pipelined batching that `batchScenario` leaves out (item
vxcuze). A batch stops before a request that consumes no byte, more bytes
than are buffered, or answers an empty response, as before one that would
pass the bound, and the connection closes when it serves that request once
the batch is sent; an empty first response (`Conn.batch`'s `first.size =
0` branch) or an oversized one (`startSend`) sends nothing, not even the
responses to the requests behind it. A batch holds at most
`Conn.maxBatchRequests` responses. Complete requests left behind either
bound are answered in consecutive batches, in order, each in an array
whose capacity is its size. A full buffer that ends on an incomplete
request is answered in several batches, then that request is read with the
room the buffer has left, under its head deadline. -/
def batchEdgeScenario : Check Unit := do
  let o := oneByte
  let closed (s : Conn.State Unit) : Bool := match s.phase with
    | .closed => true
    | _ => false
  let run (input : String) : Check (Array ByteArray × Conn.State Unit × Conn.Action) := do
    let (s, a) := Conn.step o 0 (Conn.initial o) (.received (bytes input))
    drain s!"batch edges: {input}" o 8192 s a
  let (ok, _, okA) ← run "abc"
  if ok != #[bytes "abc"] then fail "batch edges: abc is not one batch of the three responses"
  expectRecv "batch edges: after abc" okA inCap
  -- Each defensive stop: the batch ends before it, then serving it closes.
  for stop in ["Z", "O", "E", "B"] do
    let (sends, s, a) ← run s!"a{stop}b"
    if sends != #[bytes "a"] then fail s!"batch edges: a{stop}b: {sends.size} sends, not the first response alone"
    expectClose s!"batch edges: a{stop}b, after the first response" a
    unless closed s do fail s!"batch edges: a{stop}b: the connection is not closed"
  -- An empty or oversized first response closes, sending nothing.
  for first in ["E", "B"] do
    let (s, a) := Conn.step o 0 (Conn.initial o) (.received (bytes s!"{first}ab"))
    expectClose s!"batch edges: {first}ab" a
    unless closed s do fail s!"batch edges: {first}ab: the connection is not closed"
  -- The request bound (item umtm4l): `maxBatchRequests` one-byte requests
  -- are one send; one more is answered in a second send, which follows the
  -- first's completion with no receive between. (That the loop reports
  -- that completion after the connections already ready is the transport's,
  -- tested in zig/src/serve_test.zig: "connections that perform their next
  -- send during a ready turn are reported once in it and kept for the
  -- next".) The value is the one decided (item umtm4l); changing it is a
  -- decision, not a tuning.
  if Conn.maxBatchRequests != 64 then fail s!"batch edges: maxBatchRequests is {Conn.maxBatchRequests}, not the decided 64"
  for (n, sends) in [(Conn.maxBatchRequests, 1), (Conn.maxBatchRequests + 1, 2)] do
    let input := "".pushn 'a' n
    let (bs, _, ba) ← run input
    let want := if sends == 1 then #[bytes input] else #[bytes ("".pushn 'a' Conn.maxBatchRequests), bytes "a"]
    if bs != want then fail s!"batch edges: {n} one-byte requests: sends of {bs.map (·.size)} bytes, want {want.map (·.size)}"
    expectRecv s!"batch edges: after {n} one-byte requests" ba inCap
  -- Requests left behind either bound are answered in consecutive batches,
  -- as `gather` takes them (each next response while the batch stays within
  -- `maxResponseBytes` and `maxBatchRequests`): a buffer of GET / (200) and GET /nope (404) in
  -- turn, alone, or followed by an incomplete request that fills the buffer
  -- to `inCap` exactly, whose rest is then received under its head deadline
  -- in the period the last batch's head budget ran in (`gen + 1` of each
  -- send, one send per batch).
  let h := H1Adapter.adapter {} App.Hello.app
  let get := "GET / HTTP/1.1\r\nHost: a\r\n\r\n"
  let miss := "GET /nope HTTP/1.1\r\nHost: a\r\n\r\n"
  let some rGet := aloneResponse h get | fail "batch edges: GET / alone"; return
  let some rMiss := aloneResponse h miss | fail "batch edges: GET /nope alone"; return
  let head := "GET / HTTP/1.1\r\nHo"
  for incomplete in [false, true] do
    let what := if incomplete then "batch edges: a full buffer ending on an incomplete request" else "batch edges: consecutive batches"
    let mut reqs : Array String := #[]
    let mut size := 0
    for i in [0:inCap] do
      let r := if i % 2 == 0 then get else miss
      if size + r.length + head.length > inCap then break
      reqs := reqs.push r
      size := size + r.length
    let tail := if incomplete then "".pushn 'o' (inCap - size - head.length) |> (head ++ ·) else ""
    let input := String.join reqs.toList ++ tail
    if incomplete && input.length != inCap then fail s!"{what}: {input.length} bytes, not {inCap}"
    let want := ((reqs.map fun r => if r == get then rGet else rMiss).foldl (init := (#[] : Array (ByteArray × Nat))) fun bs r =>
      match bs.back? with
      | some (b, k) =>
        if b.size + r.size ≤ maxResponseBytes && k < Conn.maxBatchRequests then bs.pop.push (b ++ r, k + 1) else bs.push (r, 1)
      | none => #[(r, 1)]).map (·.1)
    if want.size < 2 then fail s!"{what}: the responses of {reqs.size} requests fit one batch"
    let (s1, a1) := Conn.step h 0 (Conn.initial h) (.received (bytes input))
    let (sends, s2, a2) ← drain what h 8192 s1 a1
    if sends != want then
      fail s!"{what}: {sends.size} sends of {sends.map (·.size)} bytes, not the responses of {reqs.size} requests in batches of {want.map (·.size)}"
    for d in sends do
      if byteArrayCapacity d != d.size then fail s!"{what}: capacity {byteArrayCapacity d} for {d.size} bytes"
    if s2.buf != bytes tail then fail s!"{what}: {s2.buf.size} bytes left, not the {tail.length} of the incomplete request"
    expectRecv what a2 (inCap - tail.length)
    expectDeadline what s2 (some (if incomplete then .head else .idle)) (sends.size + 1)

/-! ## Values the Zig and C sources state again

`zig/` cannot read a Lean definition, so it states some again; these checks
read them from the sources, relative to the repository's root (`check.sh`
runs `lsrv-test` there). `definedOnce` takes every line of `file` that
mentions both `keyword` and `name` as a definition of `name`, so one in
another spelling (`# define`, a trailing comment, parentheses) or in a
comment is not passed over; it fails unless there is exactly one, and it
reads, with runs of whitespace as one space, `want`. It checks the source's
spelling, not the compiled value: that one line hidden from the compiler (in
a comment, an inactive `#if`) would pass here, and these sources keep each
definition a plain top-level line. -/

/-- The one line of `file` defining `name`, with runs of whitespace as one
space; `none`, reported, when there is not exactly one. -/
def definition (what : String) (file : System.FilePath) (keyword name : String) : Check (Option String) := do
  let src ← try IO.FS.readFile file
    catch e => fail s!"{what}: cannot read {file}: {e}"; return none
  let mentions (line word : String) := (line.splitOn word).length > 1
  let defines := (src.splitOn "\n").filter fun line => mentions line keyword && mentions line name
  match defines with
  | [line] => return some (" ".intercalate ((line.splitToList Char.isWhitespace).filter (· ≠ "")))
  | ls => fail s!"{what}: {file} has {ls.length} lines defining {name}, want 1"; return none

def definedOnce (what : String) (file : System.FilePath) (keyword name want : String) : Check Unit := do
  if let some line ← definition what file keyword name then
    if line != want then fail s!"{what}: {file} has `{line}`, want `{want}`"

/-- The decimal value of the one line of `file` defining `name`, which reads
`pre`, the value, `post`. -/
def definedNat (what : String) (file : System.FilePath) (keyword name pre post : String) : Check (Option Nat) := do
  let some line ← definition what file keyword name | return none
  let v := ((line.dropPrefix? pre).bind (·.dropSuffix? post)).bind (·.toString.toNat?)
  if v.isNone then fail s!"{what}: {file} has `{line}`, want `{pre}<decimal>{post}`"
  return v

/-- The pool's result bound: `zig/src/pg.c` enforces `EKK_MAX_RESULT_BYTES`,
`Query.maxResultBytes`. -/
def resultBoundAgrees : Check Unit :=
  definedOnce "result bound" "zig/src/pg.c" "define" "EKK_MAX_RESULT_BYTES"
    s!"#define EKK_MAX_RESULT_BYTES {Query.maxResultBytes}"

/-- Each constructor of `Conn.Action` by the name the loop gives it, and one
value of each in `actions`; the match and `actions_cover` do not compile
until a new constructor is in both. -/
def actionName : Conn.Action → String
  | .recv _ => "recv"
  | .send _ _ => "send"
  | .close => "close"
  | .none => "none"
  | .query _ => "query"

def actions : List Conn.Action :=
  [.recv 0, .send .empty 0, .close, .none, .query { sql := "" }]

theorem actions_cover (a : Conn.Action) : a.ctorIdx ∈ actions.map (·.ctorIdx) := by
  cases a <;> simp [actions, Conn.Action.ctorIdx]

def deadlineName : Conn.Deadline → String
  | .idle => "idle"
  | .head => "head"
  | .body => "body"
  | .write => "write"

def deadlines : List Conn.Deadline := [.idle, .head, .body, .write]

theorem deadlines_cover (d : Conn.Deadline) : d ∈ deadlines := by
  cases d <;> decide

/-- The transport's codes: `glue.c` decodes `Conn.Action` by its runtime tag,
the constructor's index (`ctorIdx`), and the loop names the deadlines by
`Transport.deadlineCode`. `serve.zig` states every one (`action_*`,
`deadline_*`), and `glue.c` the action codes it decodes (`EKK_ACTION_*`);
`serve_test.zig` uses `serve.zig`'s. `serve.zig` keeps a deadline's budget
at its code less 1 in `budget_ms`, so the codes are 1 to the number of
deadlines, each once, and `budget_ms` has that many. -/
def transportCodesAgree : Check Unit := do
  let serve : System.FilePath := "zig/src/serve.zig"
  let glue : System.FilePath := "zig/src/glue.c"
  if (actions.map (·.ctorIdx)) != List.range actions.length then
    fail s!"transport codes: `actions` lists the constructors at indices {actions.map (·.ctorIdx)}, not each once in order"
  for a in actions do
    definedOnce "transport codes" serve "const" s!"action_{actionName a}"
      s!"pub const action_{actionName a}: u8 = {a.ctorIdx};"
  for a in actions.filter (actionName · ∈ ["recv", "send", "query"]) do
    definedOnce "transport codes" glue "define" s!"EKK_ACTION_{(actionName a).toUpper}"
      s!"#define EKK_ACTION_{(actionName a).toUpper} {a.ctorIdx}"
  match ← (try (some <$> IO.FS.readFile glue) catch _ => pure none) with
  | some src =>
    let n := ((src.splitOn "\n").filter fun l => (l.splitOn "define").length > 1 && (l.splitOn "EKK_ACTION_").length > 1).length
    if n != 3 then fail s!"transport codes: {glue} has {n} lines defining EKK_ACTION_*, want the 3 checked here"
  | none => pure () -- definedOnce reported it
  if (deadlines.map (·.ctorIdx)) != List.range deadlines.length then
    fail s!"transport codes: `deadlines` lists the constructors at indices {deadlines.map (·.ctorIdx)}, not each once in order"
  let codes := deadlines.map fun d => (Transport.deadlineCode d).toNat
  if codes.mergeSort != (List.range codes.length).map (· + 1) then
    fail s!"transport codes: Transport.deadlineCode gives {codes}, not 1 to {codes.length}, each once"
  definedOnce "transport codes" serve "var" "budget_ms" s!"pub var budget_ms: [{codes.length}]u32 = .\{ {", ".intercalate (List.replicate codes.length "1")} };"
  definedOnce "transport codes" serve "const" "deadline_none" "pub const deadline_none: u8 = 0;"
  for d in deadlines do
    definedOnce "transport codes" serve "const" s!"deadline_{deadlineName d}"
      s!"pub const deadline_{deadlineName d}: u8 = {Transport.deadlineCode d};"

/-- The Go programs `check.sh` runs state values of the server again, each a
`const NAME = VALUE` line: the request limits (`Server.Wire`,
`H1Adapter`), the transport's receive and send buffers (`recv_cap` and
`out_cap` of `serve.zig`, read from it), the size of `App.Fixture.body` and the query of `App.Db`.
That body takes several sends and ends with a short one (App/Fixture.lean)
only while it is longer than `out_cap` and no multiple of it. -/
def benchValuesAgree : Check Unit := do
  let serve : System.FilePath := "zig/src/serve.zig"
  let recvCap ← definedNat "bench values" serve "const" "recv_cap" "const recv_cap = " ";"
  let outCap ← definedNat "bench values" serve "const" "out_cap" "const out_cap = " ";"
  let goConst (file : System.FilePath) (name : String) (v : Nat) :=
    definedOnce "bench values" file "const" name s!"const {name} = {v}"
  let limits := [("maxHeadBytes", maxHeadBytes), ("maxBodyBytes", maxBodyBytes)]
  for (n, v) in limits do goConst "bench/check/main.go" n v
  let boundary : System.FilePath := "bench/boundary/main.go"
  for (n, v) in limits ++ [("maxHeaders", maxHeaders), ("maxPathSegments", H1Adapter.maxPathSegments),
      ("maxQueryParams", H1Adapter.maxQueryParams), ("bodySize", App.Fixture.body.size)] do
    goConst boundary n v
  if let some c := recvCap then goConst boundary "recvCap" c
  if let some c := outCap then goConst boundary "outCap" c
  -- Exactly, not through definedOnce, which collapses runs of spaces.
  let pg ← IO.FS.readFile "bench/pgserver/main.go"
  unless (pg.splitOn s!"\nconst worldSql = \"{App.Db.worldSql}\"\n").length == 2 do
    fail s!"bench values: bench/pgserver/main.go has no line `const worldSql = \"{App.Db.worldSql}\"`"
  if let some c := outCap then
    if App.Fixture.body.size ≤ c || App.Fixture.body.size % c == 0 then
      fail s!"bench values: App.Fixture.body has {App.Fixture.body.size} bytes, not over out_cap ({c}) and no multiple of it"

/-- Pins stated in more than one file, each copy checked against its source
of truth: linux/Dockerfile's debian:trixie digest in the two images of
bench/arena, bench/arena/build.sh's liburing and gcannon commits in
bench/arena/local.Dockerfile, and zig/build.zig.zon's zio (URL and hash) in
dusty-hello/build.zig.zon, which runs dusty on the zio the server uses. -/
def pinsAgree : Check Unit := do
  let what := "pins"
  if let some base ← definition what "linux/Dockerfile" "FROM" "debian:trixie@sha256:" then
    definedOnce what "bench/arena/local.Dockerfile" "FROM" "debian:trixie" base
    definedOnce what "bench/arena/gcannon.Dockerfile" "FROM" "debian:trixie" s!"{base} AS build"
  let localSrc ← IO.FS.readFile "bench/arena/local.Dockerfile"
  let localLines := (localSrc.splitOn "\n").map fun l =>
    " ".intercalate ((l.splitToList Char.isWhitespace).filter (· ≠ ""))
  for (name, repo) in [("liburing_commit", "axboe/liburing.git"), ("gcannon_commit", "MDA2AV/gcannon")] do
    if let some line ← definition what "bench/arena/build.sh" s!"{name}=" name then
      -- The value is the assignment's whole first word; a comment may follow.
      let commit := (((line.dropPrefix? s!"{name}=").map (·.toString)).getD "").splitOn " " |>.headD ""
      if commit.length != 40 || !commit.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f') then
        fail s!"{what}: bench/arena/build.sh has `{line}`, want `{name}=<40 hex digits>`"
      else
        -- The checkout must follow the clone of its own repository.
        let clone := s!"RUN git clone -q https://github.com/{repo} "
        match (localLines.zip (localLines.drop 1)).filter (·.1.startsWith clone) with
        | [(_, next)] =>
          if next != s!"&& git checkout -q {commit} \\" then
            fail s!"{what}: bench/arena/local.Dockerfile checks out `{next}` after cloning {repo}, want commit {commit}"
        | cs => fail s!"{what}: bench/arena/local.Dockerfile clones {repo} {cs.length} times, want 1"
  for key in [".url", ".hash"] do
    if let some line ← definition what "zig/build.zig.zon" key "zio" then
      definedOnce what "dusty-hello/build.zig.zon" key "zio" line

/-! ## A value stated again from upstream

`H1Adapter.errorStatus` states again the status H1's own server answers each
`H1.Error` with (the private `errorResponseStatus`). H1's machine writes that
answer itself when its `step` finds an error, so this asks it for every
error and compares the status line it writes. -/

/-- Each `H1.Error` by name, and one value of each in `h1Errors`; the match
and `h1Errors_cover` do not compile until a new constructor of a toolchain
update is in both. -/
def h1ErrorName : Std.Http.Protocol.H1.Error → String
  | .invalidStatusLine => "invalidStatusLine"
  | .invalidHeader => "invalidHeader"
  | .timeout => "timeout"
  | .entityTooLarge => "entityTooLarge"
  | .uriTooLong => "uriTooLong"
  | .unsupportedVersion => "unsupportedVersion"
  | .unsupportedTransferCoding => "unsupportedTransferCoding"
  | .unsupportedMethod => "unsupportedMethod"
  | .invalidChunk => "invalidChunk"
  | .connectionClosed => "connectionClosed"
  | .badMessage => "badMessage"
  | .tooManyHeaders => "tooManyHeaders"
  | .headersTooLarge => "headersTooLarge"
  | .other _ => "other"

def h1Errors : List Std.Http.Protocol.H1.Error :=
  [.invalidStatusLine, .invalidHeader, .timeout, .entityTooLarge, .uriTooLong, .unsupportedVersion,
   .unsupportedTransferCoding, .unsupportedMethod, .invalidChunk, .connectionClosed, .badMessage,
   .tooManyHeaders, .headersTooLarge, .other ""]

theorem h1Errors_cover (e : Std.Http.Protocol.H1.Error) : e.ctorIdx ∈ h1Errors.map (·.ctorIdx) := by
  cases e <;> simp [h1Errors, Std.Http.Protocol.H1.Error.ctorIdx]

def errorStatusAgrees : Check Unit := do
  if (h1Errors.map (·.ctorIdx)) != List.range h1Errors.length then
    fail s!"error status: `h1Errors` lists the constructors at indices {h1Errors.map (·.ctorIdx)}, not each once in order"
  for e in h1Errors do
    let m : Std.Http.Protocol.H1.Machine .receiving := { config := H1Adapter.config, error := some e }
    let line := ((String.fromUTF8! m.step.2.output.toByteArray).splitOn "\r\n").head!
    let want := s!"HTTP/1.1 {H1Adapter.errorStatus e} "
    unless line.startsWith want do
      fail s!"error status: H1 answers {h1ErrorName e} with `{line}`, H1Adapter.errorStatus with {H1Adapter.errorStatus e}"

/-- The application sees the request-target as sent, also after the empty
lines H1 accepts before the request line (`H1Adapter.rawTarget`). -/
def rawTargetCases : Check Unit := do
  for pre in ["", "\r\n", "\r\n\r\n"] do
    for (method, target) in [("GET", "/"), ("GET", "/a%20b/c?d=e&f"), ("OPTIONS", "*"), ("GET", "http://a/b?c")] do
      let buf := bytes s!"{pre}{method} {target} HTTP/1.1\r\nHost: a\r\n\r\n"
      match H1Adapter.parse buf with
      | .ok .. =>
        let got := H1Adapter.rawTarget buf
        if got != target then fail s!"raw target: {pre.length} bytes of empty lines, {method} {target}: {got}"
      | _ => fail s!"raw target: {pre.length} bytes of empty lines, {method} {target}: H1 did not accept it"

def main : IO UInt32 := do
  let ((), failures) ← (do
    resultBoundAgrees
    transportCodesAgree
    errorStatusAgrees
    benchValuesAgree
    pinsAgree
    rawTargetCases
    retainedScenario
    responseCapacityScenario
    ownFieldRule
    for ad in [h1, hand] do
      adapterCases ad
      ownFieldCases ad
      connScenario ad
      limitScenario ad
      lawCases ad
      receiveInPlaceScenario ad
    arenaScenario
    continueScenario
    refusedScenario
    queryScenario
    batchScenario
    batchEdgeScenario
    deadlineScenario
    clockScenario
    corpusScenario
    for (secs, want) in dates do
      let got := String.fromUTF8! (Response.pushDate ByteArray.empty secs)
      if got != want then fail s!"date {secs}: {got}, want {want}" : Check Unit).run 0
  IO.println s!"{failures} failures"
  return if failures == 0 then 0 else 1
