Should a complete pipelined head held in the kernel survive the end of its head budget during a slow write?

Seen in item dv6ikn (commits 0302eac, 8d76550): while a response is written, the next request's bytes stay in the kernel; the loop polls only for readiness (zig/src/serve.zig `watch`, `pollCb`). When the head budget beside the write ends (`Conn.expire` on the ahead pair, Server/Conn.lean), Lean can tell a complete head from a partial one only for bytes already in its buffer (`Conn.step_expired_ahead_complete`). A head still in the kernel is treated as partial and the connection closes, even when the whole head arrived in time and only the client's slow reading of the previous response kept the server from reading it. README "Deadlines" documents this limit.

Options:
- (a) Leave it: a client that pipelines behind a response it reads slower than the head budget (`--head-ms`, 10 s) loses the connection; such clients are rare and the write deadline bounds them anyway.
- (b) A receive lane beside the send: the loop receives into Lean's buffer while it writes (a second operation in flight per connection, with its own completion, cancellation and close ordering, and Lean events for data received during a write), so a complete head is known in time and the expiry does not close.
- (c) At the expiry only, a non-blocking peek of the kernel buffer (MSG_PEEK into a scratch buffer of the head limit) handed to Lean's adapter to decide complete vs partial, with no data consumed.
