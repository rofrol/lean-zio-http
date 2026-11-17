import Server.Query

/-! The contract between a connection (`Server.Conn`, driven by the transport)
and the protocol adapter that reads its bytes (`Server.H1Adapter` in
production, `Server.HandParser` as the comparator): the limits both sides
size their buffers by, what an adapter answers about the bytes buffered on a
connection, and the parse state it keeps on the connection between receives.
It imports only `Server.Query` (the values a waiting answer carries), so
neither side depends on the other. -/

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

/-- Whether the request is still incomplete, so the connection keeps the
adapter's state for the next call on the same request. -/
def Reply.waits : Reply → Bool
  | .needMore | .continue _ => true
  | .respond .. | .await .. => false

/-- A protocol adapter with parse state `σ`, kept on the connection so that a
request arriving in many receives is not parsed again from its start on every
receive.

`handle s buf` answers the bytes buffered on a connection, `buf`, which start
at a request boundary; `s` is what the adapter returned on its previous call
for the same request, or `init` for the request's first call. The connection
keeps the returned state while the answer `waits` (it then calls again with
`buf` extended by the bytes received meanwhile, possibly none), and starts the
next request with `init` once one is consumed (`Server.Conn`). -/
structure Adapter (σ : Type) where
  init : σ
  handle : σ → ByteArray → σ × Reply

namespace Adapter

variable {σ : Type} (ad : Adapter σ)

/-- The states a connection may pass to `handle` together with `buf`: `init`,
with any buffer, or the state `handle` returned for a prefix of `buf` when its
answer waited. -/
inductive Fed : σ → ByteArray → Prop
  | init (buf : ByteArray) : Fed ad.init buf
  | more {s : σ} {buf : ByteArray} (d : ByteArray) :
      Fed s buf → (ad.handle s buf).2.waits → Fed (ad.handle s buf).1 (buf ++ d)

/-- A state fed for `buf` is fed for any extension of it. -/
theorem Fed.extend {s : σ} {buf : ByteArray} (h : ad.Fed s buf) (d : ByteArray) : ad.Fed s (buf ++ d) := by
  cases h with
  | init => exact .init _
  | more d' h w => rw [ByteArray.append_assoc]; exact .more _ h w

/-- The adapter's law: the kept state only saves work. Whatever fragments a
request arrived in, the answer is the one `handle` gives from `init` on the
same bytes. The theorems of `Server.Conn` that compare fragmented and whole
receives assume it; `lsrv-test` checks it for both adapters (the H1 machine's
functions are `partial`, so it cannot be proved about them). -/
def Incremental : Prop := ∀ s buf, ad.Fed s buf → (ad.handle s buf).2 = (ad.handle ad.init buf).2

end Adapter

end Server
