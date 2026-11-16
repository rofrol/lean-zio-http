Keep the load generator's connection burst within the listen queue

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item qf5n6w (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Proposed by item 2l6rcv on 2026-11-16. `bench/load` dials all
`-c` connections at once; on the M1 the listen queue holds 128 unaccepted
connections (`kern.ipc.somaxconn`, macOS resets the rest), so at 256 and 512
connections runs against dusty and Go fail with `connection reset by peer` in
the first 13 to 39 ms (30-iteration loop: dusty 7/30 at c=256 and 19/30 at
c=512, Go 3/30 and 11/30, lean-zio 0/30; see "The dusty failure at 256
connections" in `README.md`). `bench.sh` therefore fails now
and then at 256 connections for a reason that is the generator's, not the
servers'. It did so in the second of two `bench.sh` runs for item 2l6rcv
(dusty c=256, `read: connection reset by peer` on 4 connections).

Question for the owner, with options:

1. Open the connections before the measurement: each connection sends one
   warm-up request and waits for its response (the event that proves the
   server accepted it), with at most 128 connections awaiting that first
   response at a time; the clock starts once every connection answered.
   Event-driven, no delays or retries; changes what the run measures only by
   excluding connection setup.
2. Leave the generator as it is and measure at most 128 connections on this
   machine (drop or lower the 256 row in `bench.sh`).
3. Leave both, and treat a reset during setup as the known failure documented
   in the README (bench.sh then stays flaky at 256).

Recommendation: option 1; acceptance runs on Linux with HttpArena are not
affected either way. Also open, informational: why lean-zio drains the queue
in time and dusty, even with 8 accept loops, does not.

Check: the 30-iteration loop from the README section passes at 256 and 512
connections for dusty and Go, and `bench.sh` exits 0.
