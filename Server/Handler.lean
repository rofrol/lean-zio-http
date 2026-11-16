/-! The interface the application implements: a pure function from a request
to a response. It imports nothing, so an application depends neither on the
parser nor on the transport (the architecture test, `Arch.lean`, enforces
that application modules import only this one and each other).

Scope: synchronous applications. A handler runs on the event loop thread that
owns the connection, so a slow handler delays every connection of that loop;
purity bounds neither its time nor its allocations. Step 6 of the server order
(non-blocking PostgreSQL owned by each loop) needs a handler that can suspend;
that is a change of this interface, decided then, not a second interface kept
beside it. -/

namespace Server

/-- A request the protocol adapter has framed and validated: Host syntax,
request-target form, framing and limits are already checked. -/
structure Request where
  /-- The method token as sent (methods are case-sensitive). -/
  method : String
  /-- The request-target as sent: for origin-form, the path and query,
  neither percent-decoded nor normalized. -/
  target : String
  /-- The Host field's value (empty for HTTP/1.0 without Host). -/
  host : String
  /-- Every header field in the order received, names lowercase. -/
  headers : Array (String × String)
  body : ByteArray

/-- What the application answers. The adapter adds Date, Content-Length and
Connection, writes no body for HEAD, and replaces a response that breaks
`Server.Response.check` (a status outside 200-599, a field it owns or with
invalid bytes, a body with 204, 205 or 304, or more than `maxResponseBytes` in
all) by 500. A CONNECT request gets 501 and never reaches the application. -/
structure Response where
  status : Nat
  /-- Extra header fields, such as Content-Type. -/
  headers : Array (String × String) := #[]
  body : ByteArray := ByteArray.empty

abbrev Handler := Request → Response

end Server
