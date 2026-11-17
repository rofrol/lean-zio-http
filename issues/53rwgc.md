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

Decided by the user 2026-11-17: option 2, run on vps.frolow.dev. This is the user's consent to load tests on that production host for this item only. The coordinating session was told beforehand, and it said, that the load generator must share the server's 2 vCPUs there, so the results understate the server; the user chose the VPS knowing that. Conditions set by the coordinating session:
- Any time: the user said on 2026-11-17 that nobody uses the VPS yet, so there is no quiet hour to wait for. Tell the ekklesiai.org session before the start and after the end, through the coordinating session.
- Never stop, restart or reconfigure the site's own services, database or firewall. Use ports and processes of the run's own, and remove everything the run installed or started when it ends.
- Stop as soon as the site's responses fail or slow down visibly (check its health URL between runs). Record that and do not resume without the user.
- Report every figure as measured with the generator on the same 2 vCPUs: a lower bound and a diagnostic, not a clean D2 acceptance. The README says so next to the numbers.

Added 2026-11-17 by the coordinating session with sol (consult call 88b30b66): before the performance runs, run the corrected epoll suite (`zig build test` in zig/, after mzqamr and emb2ob) on the VPS itself and record the result: production conclusions need it. Measure the server on epoll, as mzqamr pins it. Any io_uring figure is an experimental diagnostic only, since its behaviour differs, and it never counts toward acceptance.

2026-11-17: wi7efy (the user's request) now runs before this item. If it lands with the transport suite passing under io_uring, run that suite on the VPS under both backends as well, and count the io_uring figures as a full contender in the epoll-against-io_uring comparison. The 'experimental only' rule above holds only while io_uring is unsupported.
