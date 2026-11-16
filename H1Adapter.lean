import Http
import Std.Http.Protocol.H1

/-! Spike (item 7bccgi): the toolchain's sans-I/O HTTP/1.1 machine,
`Std.Http.Protocol.H1`, behind the same handler shape as `Http.handle`
(`ByteArray → Reply`), so that `Conn.step` can drive it without `Std.Async`.

Each call runs a fresh `Machine .receiving` over the bytes the connection has
buffered, as `Http.parse` re-parses them from the start: `feed`, then
`processRead` (start line and header block), then `pullBody` until the body is
complete (a server-side machine leaves the body to the caller, H1.lean:1861).
The response is built by `Http.respond`, the same bytes the hand-written
handler writes, so a comparison measures the parser alone. The machine's own
writer (`send`, `step`, `takeOutput`) is not used.

`Expect: 100-continue` is accepted as the hand-written handler accepts it:
the body is waited for and no interim response is sent. A chunked request
body is refused with 501 once its head is read, as `Http.parse` refuses it
(the spike's contract, README "What the Lean side does not do yet"), although
H1 could decode it. -/

namespace H1Adapter

open Std.Http Std.Http.Protocol

/-- The hand-written parser's limits (Http.lean) mapped onto H1's. H1 bounds the
start line and the header block separately (Config.lean), where `Http.parse`
bounds the whole head; `maxHeaderValueLength` is the loop's buffer, so that a
complete head over the limit gets 431 from the aggregate `maxHeaderBytes`
check (H1.lean:1828) rather than 400 from a value cut off at its own limit. -/
def config : H1.Config :=
  { maxHeaders := maxHeaders
    maxHeaderBytes := maxHeadBytes
    maxStartLineLength := maxHeadBytes
    maxUriLength := maxHeadBytes
    maxHeaderValueLength := maxHeadBytes + 4 + maxBodyBytes
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
  | bad (status : Nat)
  /-- A complete request: its head, the bytes it takes (head and body), and
  whether the connection closes after the response. -/
  | ok (head : Request.Head) (consumed : Nat) (close : Bool)

/-- Pulls body chunks until the body is complete or the input runs out. -/
partial def drainBody (m : H1.Machine .receiving) : H1.Machine .receiving :=
  match m.reader.state with
  | .readBody _ =>
    match m.pullBody with
    | (m, some _) => drainBody m
    | (m, none) => m
  | _ => m

/-- Whether the head just read framed the body as chunked. -/
def chunkedBody : H1.Reader.State .receiving → Bool
  | .readBody .chunkedSize => true
  | .continue s => chunkedBody s
  | _ => false

/-- Parses the request at the start of `buf`. -/
def parse (buf : ByteArray) : Parsed :=
  let m := (({ config } : H1.Machine .receiving).feed buf).processRead
  if chunkedBody m.reader.state then .bad 501 else
  let m := if m.isReaderAwaitingContinue then m.canContinue .continue else m
  let m := drainBody m
  match m.error with
  | some e => .bad (errorStatus e)
  | none =>
    match m.reader.state with
    | .complete => .ok m.reader.messageHead (buf.size - m.reader.input.remainingBytes) (!m.keepAlive)
    | _ => .needMore

/-- `Http.route` over H1's typed head: GET and HEAD of exactly `/`. -/
def route (h : Request.Head) : Nat × ByteArray × Bool :=
  let isRoot := match h.uri with
    | .originForm p none => p.absolute && p.segments.isEmpty
    | _ => false
  let isHead := h.method == .head
  if isRoot && (h.method == .get || isHead) then (200, helloBody, isHead) else (404, notFoundBody, isHead)

/-- `Http.handleWith` with H1 as the parser. -/
@[inline] def handleWith (router : Request.Head → Nat × ByteArray × Bool) (now : Nat) (buf : ByteArray) : Reply :=
  match parse buf with
  | .needMore => .needMore
  | .bad status => .respond buf.size (respond emptyResponse now status ByteArray.empty true false) true
  | .ok h consumed close =>
    let (status, body, isHead) := router h
    .respond consumed (respond emptyResponse now status body close isHead) close

def handle (now : Nat) (buf : ByteArray) : Reply := handleWith route now buf

end H1Adapter
