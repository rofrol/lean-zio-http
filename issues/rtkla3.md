Whether a handler's synchronous PostgreSQL error chain needs a scheduling boundary

Split from 6gmafg on 2026-11-16 (consult round 20261116-145342-a8e2): a long synchronous chain of failing queries (zero slots or database down) may monopolize a loop; 6gmafg's test (d) gathers the evidence.
Question: Should a synchronous error chain yield to the loop between queries?
Options: decide after 6gmafg's deterministic evidence | add a scheduling boundary now | keep synchronous chains
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.

Checked 2026-11-17 with sol (consult round 20261117-011832-74e7) under the user's delegation: deferred until 6gmafg's deterministic starvation evidence.

Decided 2026-11-18 by the coordinating session with sol, argon and hydrogen (consult round 20261118-181941-5f8f; calls 4a23f520, e4c9a8ea, 272fc555), under the user's delegation of 2026-11-18 to decide the remaining open questions with the models: approved (sol and argon; hydrogen preferred keeping chains synchronous): add a scheduling boundary. Keep short chains inline; after a fixed count of synchronous completions in one chain (a count, not a time), place the continuation on the loop's runnable queue so the loop serves other ready work before the chain goes on. Extend 6gmafg's test (d) for zero slots and database down: an unrelated ready callback on the same loop runs before a 10,000-query chain ends, every completion is delivered exactly once, delivery depth stays one. Update README "PostgreSQL" (a long chain may outlive the submit that started it) and the comments it cites. State the chosen count and its reason next to the constant.
