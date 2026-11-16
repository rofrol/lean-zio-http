import Conn

/-! Tests of `handle` (Http.lean) without sockets: framing of every proper
prefix, limits at their exact boundaries, status codes, connection rules,
and the Date header. Exit status 1 when any check fails. -/

/-- 0 need more, 1 respond and keep going, 2 respond and close. -/
def resultKind : Reply → UInt8
  | .needMore => 0
  | .respond _ _ close => if close then 2 else 1

def consumed : Reply → Nat
  | .needMore => 0
  | .respond n _ _ => n

def statusOf : Reply → String
  | .needMore => ""
  | .respond _ r _ => ((String.fromUTF8! r).splitOn "\r\n").head!

structure Case where
  name : String
  request : String
  kind : UInt8
  status : String
  /-- Bytes the request consumes; `none` means the whole input. -/
  consumes : Option Nat := none

def bytes (s : String) : ByteArray := s.toUTF8

def big (n : Nat) : String := String.ofList (List.replicate n 'a')

def maxHeadRequest : String :=
  -- A head of exactly maxHeadBytes (8192) bytes before CRLFCRLF.
  let fixed := "GET / HTTP/1.1\r\nHost: a\r\nX: "
  fixed ++ big (maxHeadBytes - fixed.length) ++ "\r\n\r\n"

def maxRequest : String :=
  let fixed := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 8192\r\nX: "
  fixed ++ big (maxHeadBytes - fixed.length) ++ "\r\n\r\n" ++ big maxBodyBytes

def cases : List Case := [
  { name := "GET /", request := "GET / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1, status := "HTTP/1.1 200 OK" },
  { name := "HEAD /", request := "HEAD / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1, status := "HTTP/1.1 200 OK" },
  { name := "unknown path", request := "GET /x HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1, status := "HTTP/1.1 404 Not Found" },
  { name := "method case", request := "GeT / HTTP/1.1\r\nHost: a\r\n\r\n", kind := 1, status := "HTTP/1.1 404 Not Found" },
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
  { name := "HTTP/2.0 line", request := "GET / HTTP/2.0\r\nHost: a\r\n\r\n", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "conflicting Content-Length", request := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "Content-Length list", request := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1, 1\r\n\r\na", kind := 2, status := "HTTP/1.1 400 Bad Request" },
  { name := "chunked", request := "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", kind := 2, status := "HTTP/1.1 501 Not Implemented" },
  { name := "body over the limit", request := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 8193\r\n\r\n", kind := 2, status := "HTTP/1.1 413 Content Too Large" },
  { name := "head of exactly the limit", request := maxHeadRequest, kind := 1, status := "HTTP/1.1 200 OK" },
  { name := "largest request", request := maxRequest, kind := 1, status := "HTTP/1.1 404 Not Found" },
  { name := "head over the limit", request := "GET / HTTP/1.1\r\nHost: a\r\nX: " ++ big 9000 ++ "\r\n\r\n", kind := 2, status := "HTTP/1.1 431 Request Header Fields Too Large" }
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

/-- One connection through `Conn.step` with `handle`: a request split in two
receives, a partial send, the rest of the send, the peer closing, and an event
after close. Returns the number of failed expectations. -/
def connScenario : IO Nat := do
  let h := handle 0
  let mut failures := 0
  let part1 := bytes "GET / HTTP/1.1\r\nHo"
  let (s1, a1) := Conn.step h Conn.initial (.received part1)
  match a1 with
  | .recv room => if room != Conn.inCap - part1.size then IO.println s!"FAIL conn: room {room}"; failures := failures + 1
  | _ => IO.println "FAIL conn: a partial request did not ask to receive"; failures := failures + 1
  let (s2, a2) := Conn.step h s1 (.received (bytes "st: a\r\n\r\n"))
  let some resp := (match a2 with | .send d 0 => some d | _ => none)
    | IO.println "FAIL conn: a complete request did not send from offset 0"; return failures + 1
  if s2.buf.size != 0 then IO.println "FAIL conn: the request was not consumed"; failures := failures + 1
  let (s3, a3) := Conn.step h s2 (.sent 10)
  match a3 with
  | .send d 10 => if d.size != resp.size then IO.println "FAIL conn: the rest is another response"; failures := failures + 1
  | _ => IO.println "FAIL conn: a partial send did not continue at offset 10"; failures := failures + 1
  let (s4, a4) := Conn.step h s3 (.sent (resp.size - 10))
  match a4 with
  | .recv room => if room != Conn.inCap then IO.println s!"FAIL conn: room {room} after the response"; failures := failures + 1
  | _ => IO.println "FAIL conn: a finished send did not go back to receiving"; failures := failures + 1
  let (s5, a5) := Conn.step h s4 (.received ByteArray.empty)
  match a5 with
  | .close => pure ()
  | _ => IO.println "FAIL conn: the peer closing did not close"; failures := failures + 1
  match (Conn.step h s5 (.sent 1)).2 with
  | .none => pure ()
  | _ => IO.println "FAIL conn: an event after close was acted on"; failures := failures + 1
  match (Conn.step h Conn.initial (.sent 1)).2 with
  | .close => pure ()
  | _ => IO.println "FAIL conn: a send report while reading did not close"; failures := failures + 1
  return failures

def main : IO UInt32 := do
  let mut failures ← connScenario
  for c in cases do
    let r := handle 0 (bytes c.request)
    let want := c.consumes.getD (bytes c.request).size
    if resultKind r != c.kind || statusOf r != c.status || consumed r != want then
      IO.println s!"FAIL {c.name}: kind {resultKind r} status {statusOf r} consumed {consumed r}; want kind {c.kind} status {c.status} consumed {want}"
      failures := failures + 1
  for req in framed do
    let b := bytes req
    for k in [0:b.size] do
      if resultKind (handle 0 (b.extract 0 k)) != 0 then
        IO.println s!"FAIL prefix {k} of {repr req} did not ask for more bytes"
        failures := failures + 1
  for (secs, want) in dates do
    let got := String.fromUTF8! (pushDate ByteArray.empty secs)
    if got != want then
      IO.println s!"FAIL date {secs}: {got}, want {want}"
      failures := failures + 1
  IO.println s!"{failures} failures"
  return if failures == 0 then 0 else 1
