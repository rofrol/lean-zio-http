import Server.Query

/-! The interface the application implements: a pure function from a request
to a response, which may first wait for database queries (`Server.Await`,
`Server.Query`). It imports only those values, so an application depends
neither on the parser nor on the transport (the architecture test, `Arch.lean`,
enforces that application modules import only this module, `Server.Query` and
each other).

A handler runs on the event loop thread that owns the connection, so a slow
handler delays every connection of that loop; purity bounds neither its time
nor its allocations. A query does not run on that thread's time: the
connection waits for its result while the loop serves its other connections
(README, "PostgreSQL"). -/

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

/-- The application: a response, possibly after queries (`Await.done r` when
it needs none). -/
abbrev Handler := Request → Await Response

end Server
