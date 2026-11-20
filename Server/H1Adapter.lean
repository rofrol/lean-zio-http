import Server.Wire
import Server.Handler
import Server.Response
import Std.Http.Protocol.H1

/-! The production HTTP/1.1 adapter (decision D1): the toolchain's sans-I/O
machine `Std.Http.Protocol.H1` turns the bytes buffered on a connection into a
`Server.Request` for the application's `Handler`, and the answer into a
`Server.Reply`. Only this module imports `Std.Http`; the application sees
`Server.Request` and `Server.Response` alone.

The machine lives on the connection while a request is incomplete
(`Parser`, the adapter's state in `Server.Adapter`): each call `feed`s only the
bytes received since the last one, then runs `processRead` (start line and
header block) and `pullBody` until the body is complete (a server-side machine
leaves the body to the caller, H1.lean:2027). So a request arriving in many
receives is parsed once, not again from its start on every receive; what H1
itself parses again is the line it is in the middle of (`parseWith` leaves
its input where it was on a line that has not ended, H1.lean:670), so the
cost of a request in 1-byte receives still grows with the square of its
longest line. Each request starts from a fresh machine (`Parser.init`). The
machine's own writer is not used: `Server.Response` writes the bytes.
`lsrv-bench`'s fragmentation table measures what a split costs (docs/fragmented-requests.md).

What H1 checks and this adapter relies on: request-line syntax, a registered
method (else 501), HTTP/1.0 or 1.1 (1.x above 1 read as 1.1, else 505), the
request-target's form and URI syntax, exactly one valid Host in HTTP/1.1
(RFC 9112 3.2), Content-Length and Transfer-Encoding framing, and the limits
of `config`.

Chunked request bodies are not accepted: once a valid head that frames its
body as chunked is read (`chunkedBody`), the request is answered 501 without
decoding or draining any of its body, although H1 could decode it. This is
the contract, not a gap to fill silently; the decision and what accepting
chunked bodies would need are in docs/production-contract.md, "Not yet".

`Expect: 100-continue` (RFC 9110 10.1.1): H1 pauses its reader after such a
head in HTTP/1.1 (never for HTTP/1.0, to which no 1xx may be sent). The
adapter lets it continue at once and pulls what body is buffered; if the body
is complete the final response is the answer, otherwise `Reply.continue` asks
the connection to send `100 Continue` once and wait for the body. Any other
expectation is ignored (RFC 9110 permits 417; we do not send it). -/

namespace Server.H1Adapter

open Std.Http Std.Http.Protocol

/-- Most path segments in a request-target, empty ones counted (`/a/` has 2,
`/` none): the default of Windows http.sys, `UrlSegmentMaxCount` = 255
("Http.sys registry settings for Windows", Microsoft Learn). A target with
more gets 414. -/
def maxPathSegments : Nat := 255

/-- Most query parameters in a request-target, empty ones counted (`?&` has 2,
`?` none): the common default of Node's `querystring.parse` (`maxKeys`), the
`qs` package (`parameterLimit`), Tomcat 11 (`maxParameterCount`) and PHP
(`max_input_vars`), all 1,000. Go's `net/url` allows 10,000
(`urlmaxqueryparams`), more than a `maxUriLength` target holds. A target with
more gets 414. -/
def maxQueryParams : Nat := 1000

/-- The limits of `Server.Wire` mapped onto H1's. H1 bounds the start line and
the header block separately (Config.lean), where the connection bounds the
whole buffer by `inCap`; `maxHeaderValueLength` is the whole buffer, so that a
complete head over the limit is bounded by the aggregate `maxHeaderBytes`
check alone (H1.lean:1951, 431).
The request-target's element counts are limited too: the adapter keeps the
parsed target until the request completes, and with no count limit a
`maxUriLength` target may parse into an element per byte (docs/memory.md,
"The adapter's state"). H1 answers a target over either count with 414, as
one over `maxUriLength` (`exceedsElementLimits`, H1/Parser.lean:282). -/
def config : H1.Config :=
  { maxHeaders := maxHeaders
    maxHeaderBytes := maxHeadBytes
    maxStartLineLength := maxHeadBytes
    maxUriLength := maxHeadBytes
    maxPathSegments := some maxPathSegments
    maxQueryParams := some maxQueryParams
    maxHeaderValueLength := inCap
    maxBodySize := maxBodyBytes }

/-- The status H1's own server answers each error with, which H1 keeps in
the private `errorResponseStatus`; `lsrv-test` (`errorStatusAgrees`)
compares it with what H1's machine writes for every `H1.Error`. -/
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
  /-- The request is incomplete: its head, or (once the head is accepted) its body. -/
  | needMore (need : Need)
  /-- The head asked for `100-continue` and the body is not complete. -/
  | awaitingBody
  | bad (status : Nat)
  /-- A complete request: its head, its body, the bytes it takes (head and
  body), and whether the connection closes after the response. -/
  | ok (head : Request.Head) (body : ByteArray) (consumed : Nat) (close : Bool)

/-- What the adapter keeps on a connection while a request is incomplete:
the H1 machine, the bytes of the connection's buffer already fed to it, the
body pulled so far, and whether the `100-continue` the head asked for was
granted. Its input holds the buffer's unread suffix, so `buf.size -
remainingBytes` is what the machine has consumed of the buffer. What it holds is
bounded from `config`'s limits in docs/memory.md ("The adapter's state"),
which `lsrv-test` checks against the blocks a state holds. -/
structure Parser where
  machine : H1.Machine .receiving := { config }
  fed : Nat := 0
  body : ByteArray := .empty
  continued : Bool := false

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

/-- Parses the request at the start of `buf`, given what `p` kept from the
earlier calls for it (`buf` extends the buffer of the call that returned `p`).

H1 bounds the start line and the header block separately, each by
`maxHeadBytes`; the connection's `inCap` holds one head of `maxHeadBytes` in
all. So a head (empty lines before it included, CRLFCRLF excluded) longer than
`maxHeadBytes` is refused with 431 here, complete or not, and every request the
adapter accepts fits in `inCap`: the connection never fills its buffer while
the adapter waits for more. The check runs while the head is incomplete at
the call's start; once a call has read the whole head, it has passed.

The answer does not depend on how the buffer was split into calls
(`Server.Adapter.Incremental`, which `lsrv-test` checks): this function's own
decisions read the machine's state, which H1 reaches alike however its input
was split, and the head's size and the body as accumulated across calls. -/
def Parser.parse (p : Parser) (buf : ByteArray) : Parser × Parsed :=
  let wasHead := readingHead p.machine.reader.state
  let m := (p.machine.feed (buf.extract p.fed buf.size)).processRead
  let p := { p with fed := buf.size }
  let headBytes := if readingHead m.reader.state then buf.size else buf.size - m.reader.input.remainingBytes
  if wasHead && m.error.isNone && headBytes > maxHeadBytes + 4 then ({ p with machine := m }, .bad 431) else
  if chunkedBody m.reader.state then ({ p with machine := m }, .bad 501) else
  let expects := m.isReaderAwaitingContinue
  let m := if expects then m.canContinue .continue else m
  let continued := p.continued || expects
  let (m, body) := drainBody m p.body
  -- The machine queues an event on every call that needs more input, and its
  -- output holds the interim response it writes; the adapter reads neither,
  -- so both are dropped rather than kept growing on the connection.
  let m := m.takeEvents.1.takeOutput.1
  let p := { p with machine := m, body, continued }
  match m.error with
  | some e => (p, .bad (errorStatus e))
  | none =>
    match m.reader.state with
    | .complete => (p, .ok m.reader.messageHead body (buf.size - m.reader.input.remainingBytes) (!m.keepAlive))
    | s => (p, if continued then .awaitingBody else .needMore (if readingHead s then .head else .body))

/-- Parses the request at the start of `buf` in one call. -/
def parse (buf : ByteArray) : Parsed := (Parser.parse {} buf).2

/-- The request-target exactly as sent: the bytes between the buffer's first
and second SP. H1 has validated the request line, so both exist there, and
what it accepts before that line, empty lines (RFC 9112 2.2), holds no SP;
so this does not depend on which empty lines H1 skips. `lsrv-test` checks it
after several. -/
def rawTarget (buf : ByteArray) : String := Id.run do
  let mut i := 0
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

/-- Answers the bytes buffered on a connection with the application's `app`,
given the parser state `p` kept for them; the responses the server writes
itself carry `own`'s fields. The clock reaches only the responses (`Dated`). -/
def handle (own : Server.Response.OwnFields) (app : Handler) (p : Parser) (buf : ByteArray) :
    Parser × Reply :=
  let (p, parsed) := p.parse buf
  (p, match parsed with
    | .needMore need => .needMore need
    | .awaitingBody => .continue Server.Response.continueBytes
    | .bad status => .respond buf.size fun now => (Server.Response.error own now status, true)
    | .ok h body consumed close =>
      Server.Response.reply consumed (Server.Response.answer own app (toRequest buf h body) close))

/-- The adapter the transport drives: `server_exports (Server.H1Adapter.adapter own app)`. -/
def adapter (own : Server.Response.OwnFields) (app : Handler) : Server.Adapter Parser :=
  { init := {}, handle := handle own app }

end Server.H1Adapter
