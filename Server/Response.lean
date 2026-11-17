import Server.Wire
import Server.Handler

/-! Writing HTTP/1.1 responses: the one place that turns a `Server.Response`
(or a parser's error status) into bytes, shared by both protocol adapters.
It checks what the application answered before writing it (`check`). -/

namespace Server.Response

/-! ## Byte classes (RFC 9110 5.1, 5.5) -/

@[inline] def isTChar (b : UInt8) : Bool :=
  (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ||
  b == 33 || b == 35 || b == 36 || b == 37 || b == 38 || b == 39 || b == 42 ||
  b == 43 || b == 45 || b == 46 || b == 94 || b == 95 || b == 96 || b == 124 || b == 126

/-- A field-value byte: visible ASCII, obs-text, SP or HTAB (RFC 9110 5.5). -/
@[inline] def isFieldByte (b : UInt8) : Bool := b == 9 || (b >= 32 && b != 127)

@[inline] def lower (b : UInt8) : UInt8 := if b >= 65 && b <= 90 then b + 32 else b

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

/-! ## Status lines -/

def reason : Nat → String
  | 100 => "Continue"
  | 200 => "OK"
  | 201 => "Created"
  | 204 => "No Content"
  | 205 => "Reset Content"
  | 301 => "Moved Permanently"
  | 302 => "Found"
  | 303 => "See Other"
  | 304 => "Not Modified"
  | 400 => "Bad Request"
  | 401 => "Unauthorized"
  | 403 => "Forbidden"
  | 404 => "Not Found"
  | 405 => "Method Not Allowed"
  | 413 => "Content Too Large"
  | 414 => "URI Too Long"
  | 431 => "Request Header Fields Too Large"
  | 500 => "Internal Server Error"
  | 501 => "Not Implemented"
  | 503 => "Service Unavailable"
  | 505 => "HTTP Version Not Supported"
  | _ => ""

/-- `HTTP/1.1 <status> <reason>` and CRLF (the reason may be empty, RFC 9112 4). -/
def pushStatusLine (out : ByteArray) (status : Nat) : ByteArray :=
  let o := pushNat (out.append "HTTP/1.1 ".toUTF8) status
  ((o.push 32).append (reason status).toUTF8).append "\r\n".toUTF8

/-- The interim response to `Expect: 100-continue`. -/
def continueBytes : ByteArray := "HTTP/1.1 100 Continue\r\n\r\n".toUTF8

/-! ## Checking what the application answered -/

/-- Fields the adapter writes itself, which a response must not carry. -/
def ownedFields : List String :=
  ["content-length", "transfer-encoding", "connection", "date", "keep-alive", "upgrade", "trailer"]

def validName (n : String) : Bool := !n.isEmpty && n.toUTF8.data.all isTChar

def validValue (v : String) : Bool :=
  v.toUTF8.data.all isFieldByte &&
  -- no leading or trailing whitespace (RFC 9110 5.5)
  (v.isEmpty || (v.front != ' ' && v.front != '\t' && v.back != ' ' && v.back != '\t'))

/-- Whether `status` forbids a body and its Content-Length field (RFC 9110 6.4.1, 8.6). -/
def noBody (status : Nat) : Bool := status == 204 || status == 304

def hdrDate := "Date: ".toUTF8
def hdrCL := "\r\nContent-Length: ".toUTF8
def hdrConnClose := "\r\nConnection: close".toUTF8
def crlf := "\r\n".toUTF8
def crlf2 := "\r\n\r\n".toUTF8

/-- The response's head: status line, the application's fields, Date,
Content-Length (of `r.body` also for HEAD), `Connection: close` when `close`,
and the empty line. Built in a scratch array that may grow; `write` copies it. -/
def writeHead (now : Nat) (r : Response) (close : Bool) : ByteArray := Id.run do
  let mut o := pushStatusLine (ByteArray.emptyWithCapacity 192) r.status
  for (n, v) in r.headers do
    o := (((o.append n.toUTF8).push 58).push 32).append v.toUTF8 |>.append crlf
  o := pushDate (o.append hdrDate) now
  if !noBody r.status then o := pushNat (o.append hdrCL) r.body.size
  if close then o := o.append hdrConnClose
  return o.append crlf2

/-- The response's bytes: the head (`writeHead`) and the body unless
`headOnly`, in an array whose capacity is exactly its size, so a response kept
while it is sent holds no unused capacity (README "Memory"). The capacity is a
`Nat` sum, which cannot wrap; both appends fit it, so neither grows the array. -/
def write (now : Nat) (r : Response) (close headOnly : Bool) : ByteArray :=
  let head := writeHead now r close
  let body := if headOnly || noBody r.status then ByteArray.empty else r.body
  ((ByteArray.emptyWithCapacity (head.size + body.size)).append head).append body

/-! ## Header fields on the library's own responses -/

/-- The most bytes the own fields take written (`Name: value` and CRLF each).
Every response the library writes itself then fits `maxResponseBytes`, so
none becomes a silent close (`lsrv-test` writes each with fields of exactly
this size). -/
def maxOwnFieldBytes : Nat := 4096

/-- Whether `fs` may go on the library's own responses: valid names and values
as `check` requires of the application's fields (so no CR, LF or NUL), none
the writer owns, no Content-Type (the library sets its own), and at most
`maxOwnFieldBytes` written. Names keep their spelling and order; a name may
repeat. -/
def ownFieldsValid (fs : Array (String × String)) : Bool :=
  fs.all (fun (n, v) => validName n && validValue v &&
    !ownedFields.contains n.toLower && n.toLower != "content-type") &&
  fs.foldl (fun a (n, v) => a + n.utf8ByteSize + v.utf8ByteSize + 4) 0 ≤ maxOwnFieldBytes

/-- Header fields the server adds to every final response it writes itself,
below the application: the parser's rejections (`error`), the 501 for CONNECT
and the 500 that replaces an invalid application response (`render`). Not
the application's responses, nor the interim `100 Continue`. The composition
root chooses them and passes them to the adapter, e.g.
`server_exports (Server.H1Adapter.adapter { fields := #[("X-Robots-Tag",
"noindex, nofollow")] } app)`; `valid` is proved by the kernel when the root
is built, so fields that break `ownFieldsValid` fail the build. -/
structure OwnFields where
  fields : Array (String × String) := #[]
  valid : ownFieldsValid fields = true := by decide +kernel

def contentType : String × String := ("Content-Type", "text/plain; charset=utf-8")

def internalError (own : OwnFields) : Response :=
  { status := 500, headers := #[contentType] ++ own.fields,
    body := "500 internal server error\n".toUTF8 }

/-- Whether the application's response may be written as it is. -/
def check (r : Response) : Bool :=
  200 ≤ r.status && r.status ≤ 599 &&
  r.headers.all (fun (n, v) => validName n && validValue v && !ownedFields.contains n.toLower) &&
  (!noBody r.status || r.body.isEmpty) &&
  -- 205 carries no content either; it is written with `Content-Length: 0` (RFC 9110 15.3.6).
  (r.status != 205 || r.body.isEmpty)

/-- The bytes for the application's response `r`, or for `internalError own` when
`r` fails `check` or its bytes exceed `maxResponseBytes`; the second component
says whether the connection closes after it (always after a 500 of ours). -/
def render (own : OwnFields) (now : Nat) (r : Response) (close headOnly : Bool) : ByteArray × Bool :=
  if check r then
    let bytes := write now r close headOnly
    if bytes.size ≤ maxResponseBytes then (bytes, close)
    else (write now (internalError own) true headOnly, true)
  else (write now (internalError own) true headOnly, true)

/-- The response to a request the parser rejected with `status`, with the
own fields; the connection always closes after it. -/
def error (own : OwnFields) (now : Nat) (status : Nat) : ByteArray :=
  write now { status, headers := #[contentType] ++ own.fields } true false

/-- The bytes answering a request the adapter framed, and whether the
connection closes after them, once the application's queries are answered: the
application's response (`render`; no body for HEAD), except that CONNECT gets
501 without reaching the application. A 2xx answer to CONNECT turns the
connection into a tunnel (RFC 9110 9.3.6), which this server does not
implement, so no `Response` may stand for one. The Date header is the time
of the event that sends the response (`Dated`): the receive that completed the
request, or the answer of its last query. -/
def answer (own : OwnFields) (app : Handler) (req : Request) (close : Bool) : Await Dated :=
  if req.method == "CONNECT" then .done fun now => (error own now 501, true)
  else (app req).map fun r now => render own now r close (req.method == "HEAD")

/-- The adapter's reply for a framed request of `consumed` bytes: the response
at once, or the query it waits for. -/
def reply (consumed : Nat) : Await Dated → Reply
  | .done response => .respond consumed response
  | .query q k => .await consumed q k

end Server.Response
