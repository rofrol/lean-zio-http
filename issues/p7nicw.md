Stop discarding statuses and errors that can hide a failure, and replace waits on our own processes with their events (Rule 10)

Found by the comment audit the user asked for on 2026-11-19:
- bench/arena/build.sh:86-87: `zig build test ... || true` ignores the status of the whole build and test step (meant only for the Rosetta run's ENOSYS); a compile error shows only indirectly. build.sh:94 tells serve_test from pg_test by grepping the binary for a test name.
- bench/arena/inner.sh:95 and local-inner.sh:63-65: `wait "$pid" || true` hides a crash or unclean exit of lsrv-arena after SIGTERM.
- bench/arena/inner.sh:84-91 and local-inner.sh:29: a curl loop of up to 5,000 back-to-back requests waits for the server to answer; for lsrv servers, which print "listening on", that polls our own process instead of waiting for its event.
- zig/src/pg_test.zig:417 `idle`: three non-blocking polls stand for "nothing happens" (a negative wait with an unproved count), used by absence checks such as pg_test.zig:1090.
- bench/boundary/main.go:1384: `tries = 200` readings of queues our own server drains, an unmeasured bound.
- zig/src/serve_test.zig:2050: `a.getResult() catch {` treats any error as the shutdown's cancel.
- zig/src/pg.c:182: a PQconninfoParse failure is ignored silently.
- bench/lib.sh:43: the server's output after "ready" is drained to /dev/null, so late errors are not seen.

Decided 2026-11-19 by the coordinating session with sol and hydrogen (consult round 20261119-075953-d7f4; calls 88cb5a16, 0bf8ac07) at the user's request to decide the best order of the issues with the models: approved into Next while 4bngph waits. Waits on our own processes wait for their events (the server's "listening on" line, the child's exit and status, a test hook), never a count of polls; no sleep, retry or larger bound is a fix.
