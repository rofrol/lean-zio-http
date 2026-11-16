import Server.Wire
import Server.Handler
import Server.Response

/-! The hand-written HTTP/1.1 parser: a test comparator and rollback for
`Server.H1Adapter` (decision D1), behind the same interface (`handle`), until
the Linux acceptance runs show D2 holds with H1; it is deleted then and is not
a second production path. It frames requests (head up to `maxHeadBytes`,
Content-Length body up to `maxBodyBytes`, pipelining), validates the request
line and every header field, and applies the Content-Length, Host, Connection
and Transfer-Encoding rules. Unlike H1 it does not check Host syntax or the
request-target's form, accepts any method token, and ignores
`Expect: 100-continue` (it waits for the body without an interim response);
`lsrv-compare` lists every difference. -/

namespace Server.HandParser

open Server.Response (isTChar isFieldByte lower)

/-- Case-insensitive comparison of `buf[s..e)` with the lowercase literal `lit`. -/
def eqLower (buf : ByteArray) (s e : Nat) (lit : ByteArray) : Bool := Id.run do
  if e - s != lit.size then return false
  for k in [0:lit.size] do
    if lower buf[s + k]! != lit[k]! then return false
  return true

/-- Whether the comma-separated list `buf[s..e)` holds the token `lit` (lowercase), ignoring case and OWS. -/
def listHas (buf : ByteArray) (s e : Nat) (lit : ByteArray) : Bool := Id.run do
  let mut i := s
  while i < e do
    let mut j := i
    while j < e && buf[j]! != 44 do j := j + 1
    let mut a := i
    while a < j && (buf[a]! == 32 || buf[a]! == 9) do a := a + 1
    let mut b := j
    while b > a && (buf[b - 1]! == 32 || buf[b - 1]! == 9) do b := b - 1
    if eqLower buf a b lit then return true
    i := j + 1
  return false

/-- Index of the first CRLFCRLF, searching below `limit`. -/
def findHeadEnd (buf : ByteArray) (limit : Nat) : Option Nat := Id.run do
  let stop := min buf.size limit
  let mut i := 0
  while i + 3 < stop do
    if buf[i]! == 13 && buf[i + 1]! == 10 && buf[i + 2]! == 13 && buf[i + 3]! == 10 then
      return some i
    i := i + 1
  return none

structure Head where
  methodEnd : Nat
  targetStart : Nat
  targetEnd : Nat
  minor : Nat
  /-- The Host value's bytes, empty when there is none. -/
  hostStart : Nat
  hostEnd : Nat
  /-- Where the first header field starts. -/
  fieldsStart : Nat
  contentLength : Nat
  close : Bool
  bodyStart : Nat

inductive Parsed where
  | needMore
  | bad (status : Nat)
  | ok (h : Head)

def litCL := "content-length".toUTF8
def litConn := "connection".toUTF8
def litHost := "host".toUTF8
def litTE := "transfer-encoding".toUTF8
def litClose := "close".toUTF8
def litKeepAlive := "keep-alive".toUTF8
def litHttp1 := "HTTP/1.".toUTF8

/-- Parses the request at the start of `buf`. -/
def parse (buf : ByteArray) : Parsed := Id.run do
  let some headEnd := findHeadEnd buf (maxHeadBytes + 4)
    | return if buf.size >= maxHeadBytes + 4 then .bad 431 else .needMore
  -- request-line = method SP request-target SP HTTP-version CRLF
  let mut i := 0
  while i < headEnd && isTChar buf[i]! do i := i + 1
  let methodEnd := i
  if methodEnd == 0 || buf[i]! != 32 then return .bad 400
  i := i + 1
  let targetStart := i
  while i < headEnd && buf[i]! > 32 && buf[i]! != 127 do i := i + 1
  let targetEnd := i
  if targetEnd == targetStart || buf[i]! != 32 then return .bad 400
  i := i + 1
  for k in [0:litHttp1.size] do
    if buf[i + k]! != litHttp1[k]! then return .bad 400
  i := i + litHttp1.size
  let d := buf[i]!
  if !(d == 48 || d == 49) || buf[i + 1]! != 13 || buf[i + 2]! != 10 then return .bad 400
  let minor := (d - 48).toNat
  i := i + 3
  let fieldsStart := i
  -- header fields
  let mut count := 0
  let mut contentLength : Option Nat := none
  let mut host : Option (Nat × Nat) := none
  let mut connClose := false
  let mut connKeepAlive := false
  let mut chunked := false
  while i < headEnd + 2 do
    count := count + 1
    if count > maxHeaders then return .bad 431
    let nameStart := i
    while isTChar buf[i]! do i := i + 1
    let nameEnd := i
    if nameEnd == nameStart || buf[i]! != 58 then return .bad 400
    i := i + 1
    while buf[i]! == 32 || buf[i]! == 9 do i := i + 1
    let valueStart := i
    while buf[i]! != 13 do
      if !isFieldByte buf[i]! then return .bad 400
      i := i + 1
    let mut valueEnd := i
    while valueEnd > valueStart && (buf[valueEnd - 1]! == 32 || buf[valueEnd - 1]! == 9) do
      valueEnd := valueEnd - 1
    if buf[i + 1]! != 10 then return .bad 400
    i := i + 2
    if eqLower buf nameStart nameEnd litCL then
      if valueEnd == valueStart || valueEnd - valueStart > 10 then return .bad 400
      let mut n := 0
      for k in [valueStart:valueEnd] do
        let c := buf[k]!
        if c < 48 || c > 57 then return .bad 400
        n := n * 10 + (c - 48).toNat
      if let some m := contentLength then
        if m != n then return .bad 400
      contentLength := some n
    else if eqLower buf nameStart nameEnd litHost then
      if host.isSome then return .bad 400
      host := some (valueStart, valueEnd)
    else if eqLower buf nameStart nameEnd litConn then
      connClose := connClose || listHas buf valueStart valueEnd litClose
      connKeepAlive := connKeepAlive || listHas buf valueStart valueEnd litKeepAlive
    else if eqLower buf nameStart nameEnd litTE then
      chunked := true
  if minor == 1 && host.isNone then return .bad 400
  if chunked then return .bad 501
  let cl := contentLength.getD 0
  if cl > maxBodyBytes then return .bad 413
  let bodyStart := headEnd + 4
  if bodyStart + cl > buf.size then return .needMore
  let close := connClose || (minor == 0 && !connKeepAlive)
  let (hostStart, hostEnd) := host.getD (0, 0)
  return .ok { methodEnd, targetStart, targetEnd, minor, hostStart, hostEnd, fieldsStart,
               contentLength := cl, close, bodyStart }

def text (buf : ByteArray) (s e : Nat) : String := String.fromUTF8Lossy (buf.extract s e)

/-- The header fields of a parsed head, names lowercase, values without OWS. -/
def fields (buf : ByteArray) (h : Head) : Array (String × String) := Id.run do
  let mut out := #[]
  let mut i := h.fieldsStart
  while i + 2 < h.bodyStart do
    let ns := i
    while buf[i]! != 58 do i := i + 1
    let ne := i
    i := i + 1
    while buf[i]! == 32 || buf[i]! == 9 do i := i + 1
    let vs := i
    while buf[i]! != 13 do i := i + 1
    let mut ve := i
    while ve > vs && (buf[ve - 1]! == 32 || buf[ve - 1]! == 9) do ve := ve - 1
    out := out.push ((text buf ns ne).toLower, text buf vs ve)
    i := i + 2
  return out

def toRequest (buf : ByteArray) (h : Head) : Server.Request :=
  { method := text buf 0 h.methodEnd
    target := text buf h.targetStart h.targetEnd
    host := text buf h.hostStart h.hostEnd
    headers := fields buf h
    body := buf.extract h.bodyStart (h.bodyStart + h.contentLength) }

/-- `Server.H1Adapter.handle` with this parser. -/
def handle (app : Handler) (now : Nat) (buf : ByteArray) : Reply :=
  match parse buf with
  | .needMore => .needMore
  | .bad status => .respond buf.size (Server.Response.error now status) true
  | .ok h =>
    Server.Response.reply (h.bodyStart + h.contentLength) (Server.Response.answer now app (toRequest buf h) h.close)

end Server.HandParser
