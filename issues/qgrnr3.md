Backend-independent tests of the transport's completion, cancel and expiry orderings

From the consult round of item wi7efy (sol, 2026-11-17): the transport's
integration tests (zig/src/serve_test.zig) drive real zio loops, so which
orderings of a completion, its cancel and a deadline's expiry they reach
depends on the backend (two receive tests now state io_uring's ordering
separately). Proposed: tests that deliver those events to serve.zig's
connection logic in each order explicitly (completion before / after cancel,
expiry before / after a queued `.wrote` result, several connections
re-entering the loop's ready list in one turn), checking exactly-once
reporting and the generation rules, independent of the backend. Today the
`.wrote` expiry path has one test ("a write deadline that ends while a send
the loop performed waits for its turn ..."), and the multi-connection
re-entry of the ready list is exercised only by the load runs.
