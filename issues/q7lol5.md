Should a query whose connection is lost after it was sent be answered Query.Result.abandoned instead of error 08006?

Seen in ycpzlt (consult round 20261117-132914-d1ad, sol agreed to keep it out of that item's scope): `Query.Result.abandoned` now marks only a result over `Query.maxResultBytes` (`zig/src/pg.c`, `ekk_pg_collect`, `ekk_pg_abandoned("54000", EKK_TOO_BIG)`). A connection lost while a query is in flight is still `error "08006"` (`zig/src/pg.c`, `ekk_pg_lost`; `zig/src/pg.zig` "The connection failed while busy"), though its outcome is just as unknown; the same SQLSTATE also covers a connect that failed before anything was sent (did not run) and "no database is configured". So a caller cannot tell from the structure whether an 08006 may have taken effect; `Server/Query.lean` only says that `error` does not prove the statement had no effect.

Question: Answer a query lost after it may have reached the server with `abandoned "08006"` (pg.zig tracks whether the query was handed to libpq; connect failures stay `error "08006"`), or keep every 08006 as `error` with the documented caveat?
Options: abandoned for a lost connection after the send, error for a connect failure | keep 08006 as error, documented

This changes `Server.Query`'s contract again for ekklesiai.org, so it needs the user's decision; doing it together with 3jnkx5's query expiry would move ekklesiai.org's pin once.
