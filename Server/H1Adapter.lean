import Server.Wire
import Server.Handler
import Server.Response
import Std.Http.Protocol.H1

/-! The production HTTP/1.1 adapter (decision D1): the toolchain's sans-I/O
machine `Std.Http.Protocol.H1` turns the bytes buffered on a connection into a
`Server.Request` for the application's `Handler`, and the answer into a
`Server.Reply`. Only this module imports `Std.Http`; the application sees
`Server.Request` and `Server.Response` alone.

Each call runs a fresh `Machine .receiving` over the whole buffer, from the
request boundary at its start: `feed`, then `processRead` (start line and
header block), then `pullBody` until the body is complete (a server-side
machine leaves the body to the caller, H1.lean:1861). The machine's own writer
is not used: `Server.Response` writes the bytes. Rebuilding the machine on
every receive repeats the parse of everything buffered; `lsrv-bench`'s
fragmentation table measures what that costs (README).

What H1 checks and this adapter relies on: request-line syntax, a registered
method (else 501), HTTP/1.0 or 1.1 (1.x above 1 read as 1.1, else 505), the
request-target's form and URI syntax, exactly one valid Host in HTTP/1.1
(RFC 9112 3.2), Content-Length and Transfer-Encoding framing, and the limits
of `config`. A chunked request body is refused with 501 once its head is read
(no chunked bodies yet), although H1 could decode it.

`Expect: 100-continue` (RFC 9110 10.1.1): H1 pauses its reader after such a
head in HTTP/1.1 (never for HTTP/1.0, to which no 1xx may be sent). The
adapter lets it continue at once and pulls what body is buffered; if the body
is complete the final response is the answer, otherwise `Reply.continue` asks
the connection to send `100 Continue` once and wait for the body. Any other
expectation is ignored (RFC 9110 permits 417; we do not send it). -/

namespace Server.H1Adapter

open Std.Http Std.Http.Protocol

/-- The limits of `Server.Wire` mapped onto H1's. H1 bounds the start line and
the header block separately (Config.lean), where the connection bounds the
whole buffer by `inCap`; `maxHeaderValueLength` is the whole buffer, so that a
complete head over the limit gets 431 from the aggregate `maxHeaderBytes`
check (H1.lean:1828) rather than 400 from a value cut off at its own limit. -/
def config : H1.Config :=
  { maxHeaders := maxHeaders
    maxHeaderBytes := maxHeadBytes
    maxStartLineLength := maxHeadBytes
    maxUriLength := maxHeadBytes
    maxHeaderValueLength := inCap
    maxBodySize := maxBodyBytes }

/-- The status H1's own server answers each error with: a copy of the private
`errorResponseStatus` (H1.lean:1502). -/
def errorStatus : H1.Error → Nat
  | .unsupportedVersion => 505
  | .unsupportedTransferCoding => 501
  | .unsupportedMethod => 501
  | .entityTooLarge => 413
  | .uriTooLong => 414
  | .tooManyHeaders => 431
  | .headersTooLarge => 431
  | _ => 400

inductive Parsed where
  | needMore
  /-- The head asked for `100-continue` and the body is not complete. -/
  | awaitingBody
  | bad (status : Nat)
  /-- A complete request: its head, its body, the bytes it takes (head and
  body), and whether the connection closes after the response. -/
  | ok (head : Request.Head) (body : ByteArray) (consumed : Nat) (close : Bool)

/-- Pulls body chunks until the body is complete or the input runs out. -/
partial def drainBody (m : H1.Machine .receiving) (body : ByteArray) : H1.Machine .receiving × ByteArray :=
  match m.reader.state with
  | .readBody _ =>
    match m.pullBody with
    | (m, some c) => drainBody m (body ++ c.chunk.data)
    | (m, none) => (m, body)
  | _ => (m, body)

/-- Whether the head just read framed the body as chunked. -/
def chunkedBody : H1.Reader.State .receiving → Bool
  | .readBody .chunkedSize => true
  | .continue s => chunkedBody s
  | _ => false

/-- Whether H1 is still reading the head (start line and fields). -/
def readingHead : H1.Reader.State .receiving → Bool
  | .needStartLine | .needHeader _ => true
  | _ => false

/-- Parses the request at the start of `buf`.

H1 bounds the start line and the header block separately, each by
`maxHeadBytes`; the connection's `inCap` holds one head of `maxHeadBytes` in
all. So a head (empty lines before it included, CRLFCRLF excluded) longer than
`maxHeadBytes` is refused with 431 here, complete or not, and every request the
adapter accepts fits in `inCap`: the connection never fills its buffer while
the adapter waits for more. -/
def parse (buf : ByteArray) : Parsed :=
  let m := (({ config } : H1.Machine .receiving).feed buf).processRead
  let headBytes := if readingHead m.reader.state then buf.size else buf.size - m.reader.input.remainingBytes
  if m.error.isNone && headBytes > maxHeadBytes + 4 then .bad 431 else
  if chunkedBody m.reader.state then .bad 501 else
  let expects := m.isReaderAwaitingContinue
  let m := if expects then m.canContinue .continue else m
  let (m, body) := drainBody m ByteArray.empty
  match m.error with
  | some e => .bad (errorStatus e)
  | none =>
    match m.reader.state with
    | .complete => .ok m.reader.messageHead body (buf.size - m.reader.input.remainingBytes) (!m.keepAlive)
    | _ => if expects then .awaitingBody else .needMore

/-- The request-target exactly as sent: the bytes between the request line's
first and second SP. H1 has validated the line, so both exist. -/
def rawTarget (buf : ByteArray) : String := Id.run do
  let mut i := 0
  -- H1 skips empty lines before the request line (Parser.lean:127).
  while i < buf.size && (buf[i]! == 13 || buf[i]! == 10) do i := i + 1
  while i < buf.size && buf[i]! != 32 do i := i + 1
  let s := i + 1
  let mut e := s
  while e < buf.size && buf[e]! != 32 do e := e + 1
  return String.fromUTF8Lossy (buf.extract s e)

def toRequest (buf : ByteArray) (h : Request.Head) (body : ByteArray) : Server.Request :=
  { method := toString h.method
    target := rawTarget buf
    host := ((h.headers.get? Header.Name.host).map (·.value)).getD ""
    headers := h.headers.toArray.map fun (n, v) => (n.value, v.value)
    body }

/-- Answers the bytes buffered on a connection with the application's `app`.
`now` is the wall clock in Unix seconds, for the Date header. -/
def handle (app : Handler) (now : Nat) (buf : ByteArray) : Reply :=
  match parse buf with
  | .needMore => .needMore
  | .awaitingBody => .continue Server.Response.continueBytes
  | .bad status => .respond buf.size (Server.Response.error now status) true
  | .ok h body consumed close =>
    Server.Response.reply consumed (Server.Response.answer now app (toRequest buf h body) close)

end Server.H1Adapter
