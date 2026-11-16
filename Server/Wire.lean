import Server.Query

/-! The contract between a connection (`Server.Conn`, driven by the transport)
and the protocol adapter that reads its bytes (`Server.H1Adapter` in
production, `Server.HandParser` as the comparator): the limits both sides
size their buffers by, and what an adapter answers about the bytes buffered on
a connection. It imports only `Server.Query` (the values a waiting answer
carries), so neither side depends on the other. -/

namespace Server

/-! ## Limits (Go's net/http allows 1 MiB of headers; these are smaller) -/

/-- Largest request head (request line and fields, before CRLFCRLF). -/
def maxHeadBytes : Nat := 8192
/-- Most header fields in a request. -/
def maxHeaders : Nat := 100
/-- Largest Content-Length body a request may carry. -/
def maxBodyBytes : Nat := 8192
/-- Largest response, head and body, that a connection holds and sends. A
connection keeps the whole response until its last byte is sent, so this is
the retained output memory per connection (the bounded-output contract; there
is no streaming). -/
def maxResponseBytes : Nat := 65536

/-- Bytes a connection may buffer: the largest request (maxHeadBytes, CRLFCRLF,
maxBodyBytes). -/
def inCap : Nat := maxHeadBytes + 4 + maxBodyBytes

/-- What an adapter decides about the bytes buffered on a connection, which
always start at a request boundary. -/
inductive Reply where
  /-- The request is not complete yet. -/
  | needMore
  /-- The request's head is complete and asks for `100-continue`, and its body
  is not complete: send `interim` (once per request; the connection keeps the
  buffered bytes), then receive the body. -/
  | continue (interim : ByteArray)
  /-- Send `response` for the first `consumed` bytes; close afterwards when `close`. -/
  | respond (consumed : Nat) (response : ByteArray) (close : Bool)
  /-- The first `consumed` bytes are a complete request whose answer waits for
  query `q`: run it, then continue with `k` applied to its result, which ends in
  a response to send and whether to close afterwards, as with `respond`. -/
  | await (consumed : Nat) (q : Query) (k : Query.Result → Await (ByteArray × Bool))

end Server
