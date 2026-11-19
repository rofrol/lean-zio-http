Fix stale and contradictory comments found by the comment audit

Found by the comment audit the user asked for on 2026-11-19:
- bench/pgserver/main.go:1 says it listens on 127.0.0.1:8082; line 56 listens on 127.0.0.1:0.
- zig/src/pg_glue_test.c:789 and :837 name pg.c's `result_fits`, which no longer exists (now rows_take, charge, object_cost).
- zig/src/pg_glue_test.c:28 says a reply has at most twelve results; the code allows 32.
- zig/src/serve_test.zig:30-47 keeps a hand-written record of verification runs whose counts no longer match the file.

Decided 2026-11-19 by the coordinating session with sol and hydrogen (consult round 20261119-075953-d7f4; calls 88cb5a16, 0bf8ac07) at the user's request to decide the best order of the issues with the models: approved into Next; runs while 4bngph waits for the nightly (both models).
