Measure lean-db against Go at one connection on the deployed host before deciding on spinning before parking

Item 7wvkwz (README "PostgreSQL", the Linux container paragraphs) found lean-db at 0.49 to 0.56 of go-db at c=1 in the OrbStack container (ten paired samples of 100,000 requests, `bench/dbpairs.sh`). lean-db's own database path is about 15 µs of its 90 to 102 µs p50; the rest is two waits per request, each ending in a wake-up of the loop's parked thread. Two differential runs fit the hypothesis that in the VM a wake-up of a thread whose vCPU went idle costs tens of microseconds and that Go's runtime avoids it by spinning idle threads before they park: go-db at `GOMAXPROCS=1` fell to a median of 0.86 against lean-db (0.67 to 1.33), and with every vCPU kept busy lean-db's p50 fell to 41.5 µs. On macOS lean-db leads at c=1 (1.12).

Whether this matters in production depends on the deployed host's kernel and hypervisor, which the container does not represent. The choice for the owner, stated as a question: should lean-db's loops spin (poll without blocking) for a bounded time before parking in epoll, trading idle CPU for one-connection latency?

Options:
1. First run `bench/dbpairs.sh` (and `-g 1`) on the VPS (README "HttpArena on the VPS") and decide only from that; no change if the VPS shows no gap. (Recommended: it is measurement only and decides whether there is anything to fix.)
2. Add a bounded spin before the blocking wait in the loop (a zio option or the transport's own), measured on both hosts for c=1 latency and for idle CPU at c=0 and c=64. This changes the loop's CPU use when idle, a production property, and needs the owner's approval.
3. Accept the gap as a property of the development VM and leave the loop as it is.

Smaller observation from the same trace, informational: each request makes one `recvfrom` with MSG_PEEK that fails with EAGAIN, zio's try of the re-armed peek before it parks (zig/src/pg.zig `arm`, `.recv`); it is one of nine system calls per request and was not measured on its own.
