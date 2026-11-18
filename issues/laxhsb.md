Find why the sending-memory boundary scenario once missed a connection in lsof's reading on macOS

Seen in item dtlin3 (2026-11-18, the M1, `./bench.sh` at 2ae7e98 plus dtlin3's changes, none of which touch bench/boundary, the fixture servers or the transport): the first `./bench.sh` run failed with

    FAIL memory of 100 connections each sending a response with a pipelined tail buffered: connection 88 (127.0.0.1:52888): not among the established connections read

(`bench/boundary/main.go` `memoryFull`, the check in `fill` or after it, around lines 1186-1244: a connection the client holds open was missing from `tcpQueues`, which on macOS reads `lsof -nP -a -p SERVER,CLIENT -iTCP -sTCP:ESTABLISHED -Tqs -F nT`). The scenario then passed 20 times out of 20 on its own (`bench/boundary/boundary -only "pipelined tail buffered"`, a labelled diagnostic loop) and the whole `./bench.sh` passed on the next run. The check was added on 2026-11-18 (commit 2ca3573); this is the first failure of it seen.

Not traced: whether lsof left out the socket (a state other than ESTABLISHED, or a QR/QS line missing so `tcpQueues` drops the name), whether the server closed the connection, or something else. Until it is traced it counts as an intermittent failure of the gate (AGENTS.md Rule 10: no retry or delay as a fix).

Question: trace it now (record lsof's raw output when a connection is missing, so the next failure shows which case it is), or leave it until it recurs?
Options: add the raw-output record to the failure message and trace on the next occurrence | trace it now with a stress run of the whole check.sh | leave it
