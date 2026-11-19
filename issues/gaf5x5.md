Decide whether a pipelined batch is bounded by maxResponseBytes (65,536) or by the transport's out_cap (8,192)

Item paarzq's approval (2026-11-19) says "into the out_cap-bounded out buffer". Commit 9c774f0 on rr2/paarzq bounds a batch by Lean's `maxResponseBytes` (65,536), the proved bound on Conn's out array (`Conn.step_inv`), not by Zig's `out_cap` (8,192, `zig/src/serve.zig`), the per-send copy buffer `glue.c` fills from Lean's out. A batch over 8,192 bytes therefore goes out in several system calls of at most 8,192 bytes, as a single response over 8,192 bytes already does.

Seen in: consult round 20261119-120420-c1d1, sol (call 5b71774c): "sound as one logical write bounded by maxResponseBytes, not as one out_cap-bounded transport send … needs explicit owner agreement if out_cap meant Zig's 8,192-byte buffer". hydrogen (call 9f681ce4) judged the reading sound.

Options:
1. Keep maxResponseBytes (current). No new constant; memory bound unchanged (one 81,920-byte block at most, docs/memory.md).
2. Bound a batch by 8,192: a Lean constant equal to serve.zig's out_cap, with a check (lsrv-test or the Zig build) that the two agree; each batch is then one system call when the kernel takes it whole, at the cost of one more loop turn per 8 KiB of pipelined responses and a second source of the transport's buffer size.

Recommendation: 1, unless "one system call per batch" is the property wanted.
