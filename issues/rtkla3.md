Whether a handler's synchronous PostgreSQL error chain needs a scheduling boundary

Split from 6gmafg on 2026-11-16 (consult round 20261116-145342-a8e2): a long synchronous chain of failing queries (zero slots or database down) may monopolize a loop; 6gmafg's test (d) gathers the evidence.
Question: Should a synchronous error chain yield to the loop between queries?
Options: decide after 6gmafg's deterministic evidence | add a scheduling boundary now | keep synchronous chains
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.
