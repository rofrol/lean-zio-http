Decide whether bytes pipelined behind a request that got 100 Continue start their head budget at their receive

After item udpq6h (commit 407ae1a) a pipelined request's head budget runs from the receive that brought its first byte, across every response, batch and query ahead of it. One path still starts it later: bytes that arrive behind a request with `Expect: 100-continue` while its interim response or body is handled get no head budget until that request's final response starts (`Server/Conn.lean`, `stamp`/`keepsHead`: the interim response runs under the body's deadline, `Phase.ahead` is none there). This was the case before udpq6h too. The delay is bounded by the body deadline (`--body-ms`, 30 s) plus the handler's own work.

Options: (a) keep it and state it in docs/production-contract.md "Deadlines"; (b) run the head budget beside the interim response and the body as well, which adds a third phase that carries `Phase.ahead` and its tests.

Also seen during udpq6h: `headsDone` (the complete-head exemption's walk) passes a response that closes the connection, so bytes behind such a request still count as buffered heads. This only matters for an expiry before the close response is sent, and it can only close a connection that is about to close.
