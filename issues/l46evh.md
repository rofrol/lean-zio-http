Stop Conn.step from keeping the state shared while advance runs, which copies the connection's buffer on every receive

Found by item zoswdj, 2026-11-19 (docs/reports/chunked-receive-memory.md).
Since 69c915a (ytzycm 1/2), `Server/Conn.lean`'s `step` ends with
`stamp s e (advance ad now s e)`; `stamp` reads `s.phase` and `s.gen` after
`advance`, so the generated C (`lp_lsrv_Server_Conn_step___redArg`) calls
`lean_inc_ref` on the state before `advance`, and `s.buf ++ data` in
`advance` copies the whole buffer on every receive instead of appending in
place. Observed: bench/boundary's `--chunk 7` row grew from 76.2 to 77.4 KiB
per connection to 81.3 to 93.1; a copy of main whose `step` was given an
`@[implemented_by]` reading `s.phase` and `s.gen` before `advance` measured
75.5 to 78.1 (no `lean_inc_ref` on the state in its C). Every received event
pays a copy of up to `inCap` bytes; small receives pay it quadratically.

Proposed work, a choice for the owner:
- (a) restate `step` itself so that it reads the phase and generation before
  `advance` (adjusting `stamp` and the theorems that unfold it), with no
  `implemented_by`, so the proofs keep covering the code that runs; or
- (b) keep `step` as the specification and add an `@[implemented_by]`
  version, which leaves the running code outside the theorems (not
  recommended).
In both: a check that fails when the state is shared again (for example
`lsrv-test` asserting that a receive into a buffer of spare capacity keeps
the buffer's address, or the 7-byte row given a bound), then re-measure the
`--chunk 7` row of docs/memory.md and the `lsrv-bench` table of
docs/fragmented-requests.md (measured 2026-11-17; whether before or after
69c915a was not checked), which the copy may also have changed.
