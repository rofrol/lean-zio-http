# Production contract

- **Effects precede their record, and all state is volatile.** A receive or
  a send has happened in the kernel before its event reaches `Conn.step`; a
  close is chosen before it is performed. Nothing survives the process. A
  crash between an effect and its record can leave a peer with any prefix of
  a response, possibly empty, and its request unanswered; a restarted server
  knows nothing of it. HTTP clients see a closed connection, which they
  already handle (consult round 20261116-042512-dc1f). `bench/boundary`
  kills the server right after a receive (the client sees no byte) and right
  after the third 7-byte send (the client sees at most those 21 bytes, a
  prefix of the response), then checks that a fresh server serves normally.
- **Requests.** HTTP/1.0 and 1.1 through `Std.Http.Protocol.H1`: a head of at
  most 8,192 bytes in all (H1 bounds the request line and the header block
  separately; the adapter answers a longer head, complete or not, with 431),
  at most 100 fields, a Content-Length body of at most 8,192 bytes,
  pipelining. So every request the adapter waits for fits in the connection's
  buffer (`inCap`); `lsrv-test` feeds a 10,000-byte head and the largest body
  through `Conn.step` and expects 431, not a silent close. H1 validates the
  request line, the method (unregistered: 501), the version (505), the
  request-target's form and URI syntax, exactly one Host with valid syntax in
  HTTP/1.1, and the framing; a chunked body gets 501. CONNECT gets 501 and
  never reaches the application (no tunnels). A rejected request gets its
  status and the connection closes.
- **`Expect: 100-continue`.** When a head asks for it in HTTP/1.1 and its body
  is not complete, the connection sends `HTTP/1.1 100 Continue` once and
  waits for the body (`Server.Reply.continue`, `Conn.serve_continued`); a
  body sent with the head gets the final response directly, and HTTP/1.0 gets
  no interim response. Other expectations are ignored.
- **Bounded output.** A response is written whole into one buffer of at most
  `maxResponseBytes` (65,536) bytes and sent in pieces of at most 8,192 bytes
  (the loop's send buffer). A larger response, a status outside 200-599, a
  body with 204, 205 or 304, a field the adapter owns (Content-Length,
  Transfer-Encoding, Connection, Date, Keep-Alive, Upgrade, Trailer) or a
  field name or value that is not valid becomes `500` with
  `Connection: close` (`Server.Response.check`). Streaming larger bodies is
  not offered; it would change the handler interface.
- **Deadlines.** Each connection has one deadline at a time, set by its
  phase, and while it writes a response, also the head budget of a request
  pipelined behind it; when one passes, the connection closes silently: no
  408, and bytes already sent stay sent. Every budget is a peer's budget,
  configurable from 1 ms to below 2^32 ms (another value: exit status 2):
  keep-alive idle `--idle-ms` 60,000 (nginx's `keepalive_timeout` default is
  75 s), from the end of a response with nothing buffered to the next byte;
  request head `--head-ms` 10,000 (H2O's header timeout), absolute, from the
  accept for the first request and from its first byte for a later one, also
  while the previous response is still being written (`Conn.Phase.ahead`;
  the end of that response keeps the period, `Conn.step_sent_handoff`); body
  `--body-ms` 30,000 from the head's acceptance, across an interim
  `100 Continue`; response write `--write-ms` 30,000 from the start of each
  response. A connection waiting for a query runs under no deadline of its
  own: the query's completion deadline bounds that wait, and its expiry
  reaches the handler as the query's result ([PostgreSQL](postgresql.md), "Deadlines"). `Conn.step` takes `Event.expired kind generation`:
  the loop's timer reports the phase it was armed for, and an expiry of an
  earlier phase is stale and changes nothing (`Conn.step_expired_stale`,
  `expired_old_stale`). A later request's first byte is known at the
  receive that brought it, when it came with the previous request; otherwise
  the loop, while it writes a response with nothing buffered and the send
  waits on the kernel, keeps a readiness poll on the socket beside the send
  and reports `Event.arrived` when the socket becomes readable (the bytes
  stay in the kernel; a peer's end of input counts too, and the receive
  after the response reports it). A send the kernel takes (in whole or
  in part) at the loop's first try starts no poll: the loop goes on at
  once with the response's next send, which gets the poll if it waits, or with the receive that sees
  what arrived, so that head's budget starts late by at most the server's
  own work in between. The poll costs a probe and a
  registration ([PostgreSQL measurements](reports/postgresql-throughput.md) measure that
  cost on macOS), which a
  poll on every keep-alive response would add to each request.
  Bytes that arrive while a query runs are seen when its response starts, so
  that head's budget starts late by at most the time the handler's queries
  take, each bounded by its completion deadline: for a request pipelined
  behind a query, the query deadlines bound how late its head budget starts;
  they do not make that budget absolute from the head's first byte. When the
  head budget ends during the write and the next request's head is already
  complete in the server's buffer, the budget ends without a close
  (`Conn.step_expired_ahead_complete`); a head still in the kernel is not
  read before the response is written, so it closes even when complete
  (`Conn.step_expired_ahead_partial` covers the partial head). Which of a due timer and
  a ready receive or send wins is the order zio runs their callbacks in; an
  expiry counts once it is reported, and a completion that arrives after it
  is not reported. The shutdown has its own bound, the drain ("Shutdown").
- **Admission.** At most `--max-conns` connections (default 4,096) are open
  process-wide; the rest wait in the kernel's listen queue. A loop arms its
  accept only with a free slot, and an accepted connection keeps the slot
  until its close; a loop that finds none pauses its acceptor and re-arms it
  when one of its connections closes (the liveness argument is next to
  `slots_used` in `zig/src/serve.zig`). The accept's callback then takes
  further pending connections itself with `accept(2)`, each with a slot
  reserved first, up to 64 in one callback with the one its completion
  returned, and stops earlier at `EAGAIN` or when no slot is free; it then
  re-arms (or pauses) once. zio runs the completion of an accept added from
  its own callback only on the loop's next turn, so with one connection per
  callback a loop admitted one per turn ([The over-5 s tail](reports/over-5s-tail.md)). The bound keeps one callback's work finite, so the loop's
  established connections and the other loop get their turn while a
  backlog is taken. At startup the soft `RLIMIT_NOFILE`
  is raised to fit `--max-conns` plus a reserve, or the server refuses to
  start.
- **Accept errors.** They follow zio's documented `AcceptError`
  (`src/os/net.zig` at the pin) and its advice on `Server.accept`
  (`src/net.zig`). An error of the one pending connection
  (`ConnectionAborted`: "A queued connection failed before it was
  accepted: aborted or reset by the peer, or (Linux) a network error that
  was pending on it. The queue has moved past it, so the next accept gets
  another connection"), a firewall's or security module's refusal
  (`BlockedByFirewall`, `EPERM` or `EACCES`) and a spurious `EAGAIN`
  re-arm the accept. On Linux zio maps accept(2)'s pending-connection
  errnos (`ENETDOWN`, `EPROTO`, `ENETUNREACH`, `EHOSTUNREACH`, `EHOSTDOWN`,
  `ENONET`, `ENOPROTOOPT`, `ETIMEDOUT`) to `ConnectionAborted` since
  https://github.com/lalinsky/zio/pull/934, the answer to our question
  https://github.com/lalinsky/zio/issues/931; elsewhere `EPROTO` and
  `ENETDOWN` arrive as `ProtocolFailure` and `NetworkDown` and re-arm too.
  A shortage of descriptors or memory (`EMFILE`, `ENFILE`,
  `ENOBUFS`/`ENOMEM`) backs off: "The descriptor limits and
  `SystemResources` are a temporary shortage, so a server should back off
  and accept again rather than exit on them." The loop gives back the
  accept's slot, arms no accept, and when its backoff timer ends arms it
  again, or pauses as under "Admission" when no slot is free then:
  5 ms after the first failure since a successful accept, doubling with
  each further failure up to 1 s (as Go's net/http does); a successful
  accept ends the episode. It prints `accept: <error>; backing off until
  an accept succeeds` at an episode's first failure and `accept:
  recovered` at its end. Established connections are served meanwhile, and
  the shutdown takes the timer off. Errors of the listening socket itself
  (`EOPNOTSUPP`, which zio keeps as `OperationNotSupported`: "The socket
  type does not accept connections, such as a datagram socket"; `EINVAL`)
  and errors zio does not name (`Unexpected`) end the process with status
  1 and a `fatal:` line; re-arming on them would repeat a persistent error.
- **Shutdown.** SIGTERM or SIGINT starts a graceful shutdown: each loop stops
  accepting (its armed accept is canceled; a connection accepted meanwhile is
  closed), cancels every receive in flight and declines every later one
  (`Conn.Event.refused`, which closes the connection), lets every send run to
  completion, so a response already started arrives whole and requests
  already buffered are answered, and its `loop.run` returns once nothing of
  it is in flight: every completion queued before the stop has been
  dispatched. When all loops have returned the process prints `stopped` and
  exits with status 0. A peer that does not read its response holds the
  shutdown at most for the write budget (`--write-ms`), after which its
  connection closes, and a query in flight or waiting for a pool slot at
  most for its completion budget ([PostgreSQL](postgresql.md), "Deadlines"). The
  drain bounds the whole: `--drain-ms` (default 10,000, from 1 to below
  2^32; decided 2026-11-17, item ytzycm) from a loop's stop, armed only
  while the loop has connections open and taken off when the last closes.
  When it ends, the pool answers every query (`error 57014` for one not
  yet sent, `abandoned 57014` for one running, whose session it closes
  without PQcancel) and answers later ones at once, unsent; a send in
  flight is canceled, a handler that answers after that end gets its
  connection closed instead of a response, and every connection closes;
  no send starts after that end. So a loop's shutdown ends by the drain, except
  for a connect in flight that no query waits for, which ends by its own
  `--pg-connect-ms`.
- **Transport tests.** `zig build test` in `zig/` (`bench.sh` runs it) also
  runs `src/serve_test.zig`. It drives `serve.zig`'s loops on real sockets,
  with a fake of `glue.c` that reports every call as an event, and checks
  the zio behavior the shutdown and admission rely on. (1) The shutdown's
  cancels never call back into a connection while the shutdown is walking
  the list of connections: each canceled receive comes back once, as a
  refusal. (2) A receive whose result is already queued when the cancel
  comes is dispatched once, with that result. (3) Admission works across
  two loops: after each step the test has seen (for a close, once the
  closing loop has acknowledged that the close finished), each loop
  acknowledges a snapshot of its own admission state, so the test sees both acceptors
  pause when the server is full, a connection wait in the listen queue,
  and the loop whose connection closed re-arm and take it. Taking a backlog (clients on a Unix-domain socket, whose connect
  returns once the connection is queued, all connected before the loop is
  polled): connections pending when the accept's callback runs are all
  opened in that callback, within the batch, which then re-arms at
  `EAGAIN`; a larger backlog is opened at most a batch per turn while an
  established connection's byte is reported before the last is opened;
  when the slots run out the callback stops and admission pauses until a
  close releases one; a direct accept that fails (injected,
  `fail_accept_every`) gives its slot back and the callback goes on; and
  two loops started on a pending backlog take it up to the slots, both
  pause, and a released slot takes one more. (4) The loop
  does not take its stop while the stop's notifier is still waking it.
  zio 9bef33d's `Async.notify` could let the loop take the stop, end and
  close its poller in `deinit` before notify's own wake syscall, which then
  panicked instead of the process exiting with status 0
  (https://github.com/lalinsky/zio/issues/927). The pinned zio fixes it
  (https://github.com/lalinsky/zio/pull/928): notify "is now safe to call
  at any time while the `Async` itself is alive", so the signal thread
  calls it plainly; each loop's `stop` lives in `loops`, which is never
  freed. `notify` has no point a test can pause it at, so the test
  performs its steps itself, as zio's own test does
  (`src/ev/test/async_stress.zig`), stops it before its wake syscall, lets
  a byte wake the loop, and checks that serve's shutdown waits until the
  notify finishes. With 9bef33d's steps (its `pending` was a plain counter)
  the loop takes the stop at once and the test fails.
  (5) Deadlines: a timer that ends closes the connection, and the receive
  it canceled is not reported; an expiry run before a ready receive closes
  and the bytes are not reported; a receive within one period keeps its
  armed timer and due time; a receive run before a due expiry wins, and the
  replaced deadline's expiry is not reported, only the new one's; a timer
  disarmed while its callback is already on its way is retired, and its
  callback reports nothing. Each order is forced (a timer set due at once
  after the receive is ready, or a test timer in the same batch), not
  timed. `bench/boundary`'s `deadlines` scenario checks the idle, head and
  body expiries end to end with short budgets.
  (6) The drain: one that ends with a send waiting in the kernel cancels
  it, unreported, and closes the connection; every shutdown test's run
  returns only because the drain was taken off when the last connection
  closed. The pool's tests check its end (`Pool.abort`): the running query
  abandoned, the queued one unsent, both sessions closed, a later query
  answered at once.
  (7) Orderings delivered explicitly: which order a poll
  delivers a completion, its cancel and an expiry in depends on the backend,
  so these tests hold the real completions back from `serve.zig`'s callbacks
  until the loop has completed them, then hand them over in the order the
  test names (zio's `Completion.callback`: for a completion with neither
  `rearm` nor a group or queue owner, as all of the transport's are, the
  loop does not touch it after its callback returns). They control when
  `serve.zig`'s callbacks run, not the kernel's order. An expiry before its receive's
  completion closes, unreported, whether the cancel came too late (the
  bytes) or reached it (canceled); a receive before the expiry of the
  generation it ends is reported and that expiry is stale, released
  unreported; one within the period leaves the expiry current, and it
  closes. A receive completed before the shutdown's cancel is reported once;
  one the cancel reached is refused. A performed send (`.wrote`) queued in
  the ready list when the shutdown runs is not canceled: its turn, before
  any expiry or the drain's end, reports it once; in the test the send ends
  the response, the receive Lean then asks for is refused, and the connection closes once. An expiry before a queued performed
  send (`.wrote`) closes, the send unreported; that send before the expiry
  is reported, and the expiry is stale when the send ended the response and
  current when it did not. Connections in the ready list that perform their
  next send during its turn are reported once in it and taken by the next
  turn, in order, also when one of them closed on an expiry before the
  turn. They do not assert which order a backend takes.
- **Not yet:** chunked
  request bodies, percent-decoding and query parsing, Go's larger limits.
