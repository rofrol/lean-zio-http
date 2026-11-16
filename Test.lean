import Server.Conn
import Server.H1Adapter
import Server.HandParser
import App.Hello
import App.Fixture

/-! `lsrv-test`: the server's Lean side without sockets. Each adapter (H1, the
production one, and the hand-written comparator) answers the same requests:
framing of every proper prefix, limits at their exact boundaries, status
codes, connection rules, Host and request-target validation (H1 only),
`Expect: 100-continue`, the checks on what the application answers, and the
Date header. Connection scenarios drive `Conn.step` through partial receives,
partial sends, the interim response and the shutdown's `refused`. Exit status
1 when any check fails. -/

open Server

/-- 0 need more, 1 respond and keep going, 2 respond and close, 3 interim response. -/
def resultKind : Reply → UInt8
  | .needMore => 0
  | .continue _ => 3
  | .respond _ _ close => if close then 2 else 1

def consumed : Reply → Nat
  | .respond n _ _ => n
  | _ => 0

def responseOf : Reply → String
  | .respond _ r _ => String.fromUTF8! r
  | .continue r => String.fromUTF8! r
  | .needMore => ""

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
  handle : Handler → Nat → ByteArray → Reply

def h1 : Adapter := { name := "H1", handle := H1Adapter.handle }
def hand : Adapter := { name := "hand-written", handle := HandParser.handle }

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
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => { status := 200, headers := #[("Content-Length", "1")] } },
  { name := "response field with CRLF", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => { status := 200, headers := #[("X", "a\r\nY: b")] } },
  { name := "204 with a body", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => { status := 204, body := "x".toUTF8 } },
  { name := "205 with a body", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => { status := 205, body := "x".toUTF8 } },
  { name := "205", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1,
    status := "HTTP/1.1 205 Reset Content", app := fun _ => { status := 205 } },
  { name := "status 99", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 2,
    status := "HTTP/1.1 500 Internal Server Error", app := fun _ => { status := 99 } },
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
  let h := ad.handle App.Hello.app 0
  let w := s!"conn {ad.name}"
  let part1 := bytes "GET / HTTP/1.1\r\nHo"
  let (s1, a1) := Conn.step h Conn.initial (.received part1)
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
  expectClose s!"{w}: a send report while reading" (Conn.step h Conn.initial (.sent 1)).2

/-- `Expect: 100-continue` through `Conn.step` with H1: the interim response is
sent once, also across a partial send and a body arriving in two parts, and
the final response follows the body. -/
def continueScenario : Check Unit := do
  let h := H1Adapter.handle App.Fixture.app 0
  let head := bytes "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"
  let (s1, a1) := Conn.step h Conn.initial (.received head)
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
  let h := ad.handle App.Hello.app 0
  let b := bytes (splitHead ++ big maxBodyBytes)
  let mut s := Conn.initial
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
  let h := H1Adapter.handle App.Hello.app 0
  expectClose "refused while reading" (Conn.step h Conn.initial .refused).2
  let (s, _) := Conn.step h Conn.initial (.received (bytes "GET / HTTP/1.1\r\nHo"))
  expectClose "refused with a partial request" (Conn.step h s .refused).2

def adapterCases (ad : Adapter) : Check Unit := do
  for c in cases do
    let r := ad.handle c.app 0 (bytes c.request)
    let (kind, status) := if ad.name == hand.name then c.hand.getD (c.kind, c.status) else (c.kind, c.status)
    let want := c.consumes.getD (if kind == 0 then 0 else (bytes c.request).size)
    if resultKind r != kind || statusOf r != status || consumed r != want then
      fail s!"{ad.name} {c.name}: kind {resultKind r} status {statusOf r} consumed {consumed r}; want kind {kind} status {status} consumed {want}"
  for req in framed do
    let b := bytes req
    for k in [0:b.size] do
      if resultKind (ad.handle App.Hello.app 0 (b.extract 0 k)) != 0 then
        fail s!"{ad.name} prefix {k} of {repr req} did not ask for more bytes"
  -- HEAD: the GET's Content-Length, no body.
  let r := responseOf (ad.handle App.Hello.app 0 (bytes "HEAD / HTTP/1.1\r\nHost: a\r\n\r\n"))
  if !r.endsWith "\r\nContent-Length: 13\r\n\r\n" then fail s!"{ad.name} HEAD: {repr r}"

def main : IO UInt32 := do
  let ((), failures) ← (do
    for ad in [h1, hand] do
      adapterCases ad
      connScenario ad
      limitScenario ad
    continueScenario
    refusedScenario
    for (secs, want) in dates do
      let got := String.fromUTF8! (Response.pushDate ByteArray.empty secs)
      if got != want then fail s!"date {secs}: {got}, want {want}" : Check Unit).run 0
  IO.println s!"{failures} failures"
  return if failures == 0 then 0 else 1
