Bring the pool's libpq calls in line with libpq's documented call order, or cite the passage that allows them

Found by the comment audit the user asked for on 2026-11-19:
- zig/src/pg.zig:274-275: `connect` calls PQconnectPoll (`connectStep`) right after PQconnectStartParams. libpq's docs ("Connection Control Functions", PQconnectStartParams): "If you have yet to call PQconnectPoll, i.e., just after the call to PQconnectStart, behave as if it last returned PGRES_POLLING_WRITING", i.e. wait for writability first. No comment justifies the deviation; it matters for `hostaddr` TCP connects.
- zig/src/pg.c:69 (with :120, :570): on a statement's first use PQsetChunkedRowsMode is called inside `collect`, after PQconsumeInput/PQgetResult ran; libpq's general rule is "immediately after PQsendQuery ..., before any other operation on the connection such as PQconsumeInput or PQgetResult". The comment paraphrases libpq's internal check instead of quoting a documented passage (the pipeline-mode section may cover it); code aborts if libpq refuses.
Verify each against the libpq 17 docs; fix or quote the allowing passage next to the code.
