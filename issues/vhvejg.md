Measure the step cost of a large pipelined batch and the quadratic copying of the receive buffer's suffix

`Conn.gather` (Server/Conn.lean, commit 9c774f0) consumes each answered request with `buf.extract consumed buf.size`, copying the rest of the buffer once per request. With a full 16,388-byte buffer of about 600 small requests this copies about 5 MB in one `Conn.step` (one loop turn), where before the same copies were spread over one turn per response. The cost per request is unchanged, but one connection now holds the loop for all of it, which may delay another ready connection.

Seen in: consult round 20261119-120420-c1d1, sol (call 5b71774c, "measure worst-case step cost and service of a second ready connection before calling the input cap a fairness bound") and hydrogen (call 9f681ce4, "O(buf.size^2 / min_consumed) transient allocation").

Proposed work: measure (lsrv-parsebench or a bench case) the time of one step on a full buffer of minimal pipelined requests and the latency of a second connection served by the same loop meanwhile; if it matters, let the adapter take an offset into the buffer (no suffix copy) instead of a new ByteArray per request. That is an Adapter interface change, which may need approval.

Decided 2026-11-19 by the coordinating session with sol and hydrogen (consult round 20261119-131820-9a89; calls 2457b2df, db84fdb7) under the user's delegation to decide the next items with the models: approved into Next (both), measurement only: worst-case step cost and the service latency of a second ready connection on the same loop; any Adapter or Conn change comes back for approval.
