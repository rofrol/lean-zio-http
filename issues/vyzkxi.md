Decide whether the gate should guard against ephemeral-port exhaustion left by the boundary suite's TIME_WAIT sockets on macOS

Seen in item laxhsb (2026-11-18, the M1): the boundary suite run as `check.sh` runs it (`bench/boundary/boundary`, then `-no-continue -fixture .lake/build/bin/lsrv-fixture-hand`) raises the kernel's TCP PCB count (`sysctl -n net.inet.tcp.pcbcount`) from about 800 to about 7,500 (10 runs: 7,459 to 7,956), of the 16,384 ports in `net.inet.ip.portrange.first`..`last` (49152-65535). TIME_WAIT lasts 2*MSL = 30 s (`net.inet.tcp.msl` 15000). Run back to back with no pause, the third pair failed twice out of two loops with

    FAIL memory of 400 connections holding a request line whose target has 8,176 empty query parameters: connection 35: dial tcp 127.0.0.1:56379: connect: can't assign requested address

(EADDRNOTAVAIL; pcbcount 15,824 just after, falling to 13,835 within seconds). Once each run started below 1,000 PCBs, 34 runs out of 34 passed. So a `./bench.sh` or `./check.sh` started within about 30 s of another connection-heavy run on the same machine (a previous gate, a load run, another worktree's gate) can fail for a reason that is not the change under test. Not seen in a gate run so far; not tied to laxhsb's lsof miss (that was a lookup failure, not a dial failure).

Question: should the gate do anything about it?
Options: have check.sh report the PCB count and the port range at the start and in a boundary dial failure, so such a failure names its cause | have the boundary suite reuse fewer ports (e.g. fewer connections per scenario where the bound allows) | document it in the README's "Running" and leave the gate as is | leave it
