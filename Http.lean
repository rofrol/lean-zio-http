/-! Spike: the HTTP/1.1 protocol work of the server, done in Lean.
`handle` looks at the bytes buffered on a connection: it frames the request
(head and Content-Length body), validates the request line and header fields,
applies the connection rules, routes, and builds the whole response with
Content-Type, Date and Content-Length. `Conn.lean` owns the connection and
calls it. -/

/-! ## Limits (Go's net/http: 1 MiB of headers; ours are smaller, stated here) -/
def maxHeadBytes : Nat := 8192
def maxHeaders : Nat := 100
def maxBodyBytes : Nat := 8192

/-! ## Byte helpers -/

@[inline] def isTChar (b : UInt8) : Bool :=
  (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ||
  b == 33 || b == 35 || b == 36 || b == 37 || b == 38 || b == 39 || b == 42 ||
  b == 43 || b == 45 || b == 46 || b == 94 || b == 95 || b == 96 || b == 124 || b == 126

/-- A field-value byte: visible ASCII, obs-text, SP or HTAB (RFC 9110 5.5). -/
@[inline] def isFieldByte (b : UInt8) : Bool := b == 9 || (b >= 32 && b != 127)

@[inline] def lower (b : UInt8) : UInt8 := if b >= 65 && b <= 90 then b + 32 else b

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

/-- Index of the first CRLFCRLF at or after `from`, searching below `limit`. -/
def findHeadEnd (buf : ByteArray) (limit : Nat) : Option Nat := Id.run do
  let stop := min buf.size limit
  let mut i := 0
  while i + 3 < stop do
    if buf[i]! == 13 && buf[i + 1]! == 10 && buf[i + 2]! == 13 && buf[i + 3]! == 10 then
      return some i
    i := i + 1
  return none

/-! ## Parsing -/

structure Head where
  methodEnd : Nat
  targetStart : Nat
  targetEnd : Nat
  minor : Nat
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
  -- header fields
  let mut count := 0
  let mut contentLength : Option Nat := none
  let mut hasHost := false
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
      if hasHost then return .bad 400
      hasHost := true
    else if eqLower buf nameStart nameEnd litConn then
      connClose := connClose || listHas buf valueStart valueEnd litClose
      connKeepAlive := connKeepAlive || listHas buf valueStart valueEnd litKeepAlive
    else if eqLower buf nameStart nameEnd litTE then
      chunked := true
  if minor == 1 && !hasHost then return .bad 400
  if chunked then return .bad 501
  let cl := contentLength.getD 0
  if cl > maxBodyBytes then return .bad 413
  let bodyStart := headEnd + 4
  if bodyStart + cl > buf.size then return .needMore
  let close := connClose || (minor == 0 && !connKeepAlive)
  return .ok { methodEnd, targetStart, targetEnd, minor, contentLength := cl, close, bodyStart }

/-! ## Date header (IMF-fixdate), from Unix seconds -/

def dayNames : Array String := #["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
def monthNames : Array String :=
  #["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

@[inline] def push2 (out : ByteArray) (n : Nat) : ByteArray :=
  (out.push (48 + (n / 10).toUInt8)).push (48 + (n % 10).toUInt8)

/-- Appends e.g. `Mon, 16 Nov 2026 01:40:20 GMT` (civil-from-days, H. Hinnant). -/
def pushDate (out : ByteArray) (secs : Nat) : ByteArray := Id.run do
  let days := secs / 86400
  let sod := secs % 86400
  let z := days + 719468
  let era := z / 146097
  let doe := z - era * 146097
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let day := doy - (153 * mp + 2) / 5 + 1
  let month := if mp < 10 then mp + 3 else mp - 9
  let year := yoe + era * 400 + (if month <= 2 then 1 else 0)
  let mut o := out.append dayNames[days % 7]!.toUTF8
  o := (o.push 44).push 32
  o := push2 o day
  o := o.push 32
  o := o.append monthNames[month - 1]!.toUTF8
  o := o.push 32
  o := push2 o (year / 100)
  o := push2 o (year % 100)
  o := o.push 32
  o := push2 o (sod / 3600)
  o := o.push 58
  o := push2 o (sod % 3600 / 60)
  o := o.push 58
  o := push2 o (sod % 60)
  return o.append " GMT".toUTF8

def pushNat (out : ByteArray) (n : Nat) : ByteArray :=
  out.append (toString n).toUTF8

/-! ## Responses and routing -/

def statusLine : Nat → ByteArray
  | 200 => "HTTP/1.1 200 OK\r\n".toUTF8
  | 400 => "HTTP/1.1 400 Bad Request\r\n".toUTF8
  | 404 => "HTTP/1.1 404 Not Found\r\n".toUTF8
  | 413 => "HTTP/1.1 413 Content Too Large\r\n".toUTF8
  | 431 => "HTTP/1.1 431 Request Header Fields Too Large\r\n".toUTF8
  | _ => "HTTP/1.1 501 Not Implemented\r\n".toUTF8

def hdrTextPlain := "Content-Type: text/plain; charset=utf-8\r\n".toUTF8
def hdrDate := "Date: ".toUTF8
def hdrCL := "\r\nContent-Length: ".toUTF8
def hdrConnClose := "\r\nConnection: close".toUTF8
def crlf2 := "\r\n\r\n".toUTF8
def helloBody := "Hello, World!".toUTF8
def notFoundBody := "404 page not found\n".toUTF8

/-- Appends the response to `out`. -/
def respond (out : ByteArray) (now : Nat) (status : Nat) (body : ByteArray) (close head : Bool) : ByteArray :=
  let o := out.append (statusLine status)
  let o := o.append hdrTextPlain
  let o := pushDate (o.append hdrDate) now
  let o := pushNat (o.append hdrCL) body.size
  let o := if close then o.append hdrConnClose else o
  let o := o.append crlf2
  if head then o else o.append body

def route (buf : ByteArray) (h : Head) : Nat × ByteArray × Bool :=
  let isRoot := h.targetEnd == h.targetStart + 1 && buf[h.targetStart]! == 47
  -- Methods are case-sensitive (RFC 9110 9.1): exact bytes.
  let isGet := h.methodEnd == 3 && buf[0]! == 71 && buf[1]! == 69 && buf[2]! == 84
  let isHead := h.methodEnd == 4 && buf[0]! == 72 && buf[1]! == 69 && buf[2]! == 65 && buf[3]! == 68
  if isRoot && (isGet || isHead) then (200, helloBody, isHead) else (404, notFoundBody, isHead)

/-- What `handle` decides about the bytes buffered on a connection. -/
inductive Reply where
  /-- The request is not complete yet. -/
  | needMore
  /-- Send `response` for the first `consumed` bytes; close afterwards when `close`. -/
  | respond (consumed : Nat) (response : ByteArray) (close : Bool)

def emptyResponse : ByteArray := ByteArray.emptyWithCapacity 192

/-- Frames and validates the request at the start of `buf` and answers it with
`router` (status, body, head-only). `now` is the wall clock in Unix seconds,
for the Date header. -/
@[inline] def handleWith (router : ByteArray → Head → Nat × ByteArray × Bool) (now : Nat) (buf : ByteArray) : Reply :=
  match parse buf with
  | .needMore => .needMore
  | .bad status => .respond buf.size (respond emptyResponse now status ByteArray.empty true false) true
  | .ok h =>
    let (status, body, isHead) := router buf h
    .respond (h.bodyStart + h.contentLength) (respond emptyResponse now status body h.close isHead) h.close

def handle (now : Nat) (buf : ByteArray) : Reply := handleWith route now buf
