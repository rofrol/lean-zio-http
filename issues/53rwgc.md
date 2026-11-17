Linux acceptance runs for the Lean HTTP server

Moved on 2026-11-16 from ekklesiai.org's queue, where it was item pihgvg (moved by its item m4jfmv). Item ids and decisions (D1, D2) named below are ekklesiai.org's; paths are this repository's.

Step 4 of the order approved in item dqsipn ("Order (D3)" and the speed requirement D2), split out of dqsipn on 2026-11-16.

Run HttpArena's HTTP/1.1 profiles that the server owns with its pinned Linux scripts, on 2 vCPUs (the production VPS's allocation), against go-stdlib (floor) and go-fasthttp (target): five independent runs with their spread, correct responses and zero unexpected errors, epoll against io_uring, with the load generator on separate cores, and memory under the `async` profile.

Question: Where may these runs happen: on vps.frolow.dev (shared, 2 vCPUs, the production host; load tests there need the user's consent), on the 2010 MacBook (x86_64 Guix System on the LAN, 2 cores), or on a rented Linux machine?
Options: vps.frolow.dev at a quiet hour | the 2010 MacBook | a rented machine
Checked 2026-11-16: the handoff note forbids load tests on vps.frolow.dev without the user's consent; D2 asks for the VPS's CPU allocation.

Sol (consult round 20261116-145342-a8e2) on the MacBook: useful for Linux diagnostics, not for D2 acceptance, since two cores cannot give the server two CPUs and the load generator separate cores. Recommendation: a rented machine.

Also run the PostgreSQL pool tests (`zig build test` in zig/, run by bench.sh) on epoll: they have run only on macOS (kqueue) so far (item jl63fo, 2026-11-16).

Checked 2026-11-17 with sol (consult round 20261117-011832-74e7) under the user's delegation: stays with the user: renting costs money and load tests on vps.frolow.dev need consent. Acceptance needs two server CPUs plus separate generator cores; the 2010 MacBook can serve diagnostics and epoll pool tests, not acceptance.

2026-11-17: the epoll PostgreSQL pool tests moved to ogcdwm, which runs them on the 2010 MacBook as diagnostics. This item keeps only the performance acceptance runs.
