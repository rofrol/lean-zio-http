Derive or mechanically check the values copied by hand between languages, files and upstream

Found by the comment audit the user asked for on 2026-11-19. Second sources of truth with no check that they agree:
- Conn.Action's constructor order (recv 0 ... query 4) and the deadline codes, copied into zig/src/glue.c:35-50, zig/src/serve.zig:34-44 and :1020-1025, and serve_test.zig:88-92; a reorder in Server/Conn.lean breaks the transport silently.
- Server/H1Adapter.lean:59 `errorStatus`, "a copy of the private errorResponseStatus (H1.lean:1512)".
- Server/H1Adapter.lean:155 `rawTarget` re-scans the request line by hand, repeating H1's skipping of empty lines (Parser.lean:127).
- The query-result cost model in zig/src/pg.c:327-386 copies Lean's allocation sizes; its test (pg_glue_test.c:837 `built_cost`) calls the same `object_cost`, so it is circular; nothing compares with real block sizes (as test/retained.c does).
- 8192 (`recv_cap`, `maxBodyBytes`) and H1's 100 fields hard-coded in bench/boundary/main.go (1177, 1248, 1362, 1493, 1502, 1725) and bench/check/main.go:35-37.
- The debian:trixie digest in three Dockerfiles; liburing/gcannon commits hard-coded in bench/arena/local.Dockerfile:12,15 (build.sh:29-30 pins them); the zio pin in dusty-hello/build.zig.zon and zig/build.zig.zon.
- The expected row {"id":42,"randomNumber":2599} in bench/lib.sh, bench/dbcheck/main.go:220, bench.sh:79, bench/dbpairs.sh:86; bench/pgserver's copy of App.Db's query; `cpu()` copied from bench.sh into bench/rows.sh although bench/lib.sh exists.
- Arch.lean's import rules beside docs/modules.md's table.
Prefer deriving one from the other; where that is not possible, a check in check.sh that fails on disagreement (pg.c's maxResultBytes line, checked by Test.lean `resultBoundAgrees`, is the model).

Added 2026-11-19 from the audit's second pass over the Lean tests (Test.lean:47-56 against Corpus.lean:16-26 checked by the coordinating session):
- Test.lean:47-56 redefines `big`, `maxHeadRequest` and `maxRequest` word for word from Corpus.lean:16-26, although it imports Corpus.
- Test.lean (:49, :62, :111), Corpus.lean (:18-26, :62-69) and Compare.lean:208-237 write sizes derived from maxHeadBytes, maxHeaders and maxBodyBytes as literals (`Content-Length: 8192`, 8193, 100/101, labels "(8192 B)", "(16388 B)"); Corpus.lean:69 `fragmentCorpus` selects rows by those label strings, so editing a label silently drops a row from lsrv-test and lsrv-bench.
- Compare.lean:208-237: the rows "field lines of 8192/8193 bytes (H1's count)" expect 431 from the adapter's whole-head bound, which their request already exceeds, so H1's own field-bytes limit is never probed at its boundary; it also cites H1.lean line numbers without a pinned commit.
- App/Fixture.lean:13: the 60,001-byte body is repeated in bench/boundary/main.go:42, and its "several sends, ends with a short one" property depends on serve.zig's out_cap (8192), unchecked.
- Test.lean:699-736, :825: the memory bounds (163,880, 1,024, 81,920) are repeated by hand in docs/memory.md, and the exact `retainedBytes out != 81920` rests on mimalloc's size classes (with jexowc's test/retained.c point).
