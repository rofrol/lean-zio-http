Write a connection's pipelined responses with one send, as go-fasthttp does, instead of one send and one loop turn per response

Found by item 6p6tu6 (docs/reports/over-5s-tail.md, "What a pipelined response costs").

lsrv-arena makes 1.02 `sendto` per pipelined response; go-fasthttp 0.063 (one per 16), go-stdlib 1.02. The transport tries each send itself and reports it on the next loop turn (`LoopCtx.readyCb`); only then does `Conn.step` take the next request from the buffer, so 16 pipelined requests take 16 sends and 16 turns. The send is 34 % of the server's CPU in pipelined (27 % in the kernel's sendto with loopback delivery). Server CPU per pipelined response locally: 9.2 µs (go-stdlib 7.4, go-fasthttp 0.8).

Options:
1. Let Conn.step answer every complete request already in the receive buffer before sending, appending responses to the out buffer (bounded by out_cap), and send once. Changes the Conn state machine (ekk) and its proofs/tests of ordering and backpressure; non-trivial, the core's step contract.
2. Keep one send per response; pipelined throughput stays bounded by the send's cost. The tail is fixed by the accept proposal alone.

Recommendation: decide after the accept fix and a re-measurement, since the arena's current figures cover only half the connections.

Considered 2026-11-17 by the coordinating session with sol (consult call 36443c1b): later, third, after remeasurement. A change to the core's step contract needs tests of ordering, partial writes, bounded buffers and backpressure.

Decided 2026-11-19 by the coordinating session with sol, argon and hydrogen (consult round 20261119-003634-0938; calls 6335ef0f, 373e193f, c47aa49a), at the user's request to decide the queue's order with the models: approved, third, after owgate. Batch the responses to the complete requests already in the receive buffer into the out_cap-bounded out buffer and send once. Conditions: tests (or proofs) of response order, partial writes, the out_cap bound and backpressure in Conn.step; local verification only (./check.sh, ./bench.sh, ./linux-check.sh), no VPS load run; no sleep, retry or delay. A later remeasurement on real hardware happens once, together, after 4bngph, owgate and paarzq, preferably as 2ltibq's clean run.
