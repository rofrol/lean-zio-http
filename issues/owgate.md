Find where H1's parse spends 40 % of lsrv-arena's CPU (about 4-6 µs per request), or accept that cost

Found by item 6p6tu6 (README, "What a pipelined response costs").

`H1Adapter.Parser.parse` takes 41 % (pipelined) and 39 % (baseline) of the server's CPU samples locally; by function Lean's allocator and reference counting take about 20 % of all samples. Each request starts a fresh `Std.Http.Protocol.H1` machine fed `buf.extract p.fed buf.size` (a copy of the buffer's rest). Per request the parse costs about 3.8 µs pipelined and 5.9 µs baseline, so it is not a re-parse of the whole buffer, but the copy and the machine's allocations are per request.

Options:
1. Profile the H1 machine itself (perf with call graphs over a parse micro-benchmark) and propose fixes upstream to leanprover/lean4's Std.Http where they are its own (Rule 6: fork and PR, no local workaround).
2. Avoid the per-request copy in our adapter if H1 can be fed a slice/offset within its documented contract.
3. Accept the cost and record it.

Recommendation: 1 then 2, as a separate item after the accept fix.

Considered 2026-11-17 by the coordinating session with sol (consult call 36443c1b): later, after the accept fix and measurements under the corrected load. Profile first. Pursue upstream parser fixes, or feeding H1 a slice within its documented contract, only where the evidence warrants.

Decided 2026-11-19 by the coordinating session with sol, argon and hydrogen (consult round 20261119-003634-0938; calls 6335ef0f, 373e193f, c47aa49a), at the user's request to decide the queue's order with the models: approved, second after 4bngph (sol and hydrogen; argon put paarzq first). Starts only after 4bngph has landed, so it measures the H1 parser of PR 16562. Scope: local profiling only (a parse micro-benchmark and a call-graph profile on the M1 and in the Linux container), no VPS load run. Feed H1 a slice or offset only if H1's documented contract already allows it; anything inside Std.Http follows Rule 6, and any upstream issue or PR is a separate item for the owner's go. Record the measured cost and the outcome in README. paarzq waits for it, so the adapter's buffer handling is settled first.
