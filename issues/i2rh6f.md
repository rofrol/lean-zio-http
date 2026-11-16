Behavior of the PostgreSQL pool while the database is down

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item wmmvb3 (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Seen in aazqxm: with the database stopped, every query starts a fresh connection attempt (connect on demand, no retries, no timers; `zig/src/pg.zig` dispatch), so a request flood becomes a connect flood against a failing server, each answered 503 (dbcheck "down"). Decide whether that is acceptable or whether the pool should fail fast between attempts driven by an event (e.g. a connect attempt in flight serves all waiters), without a timer-driven retry loop.

Question: While the database is down, keep connect-per-query, or coalesce so one connect attempt in flight serves all waiters (and what each waiter gets)?
Options: coalesce, with waiter outcomes decided explicitly | keep connect-per-query and document it
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.
