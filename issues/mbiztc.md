Should bench.sh fail when lean-db/go-db falls below its 0.9 goal?

Needs a decision. Item fszibv measured the ratio in fifteen interleaved
rounds before and after item 3jnkx5's deadlines (README, "PostgreSQL", the
table after the throughput measurement): the median stayed at 1.08 to 1.10
(c=1) and 1.02 to 1.03 (c=64), CPU per request did not move, but single
rounds on this shared M1 ranged from 0.47 to 7.83 while other work ran
(load average 11 to 63 on 10 cores). One run of `bench.sh` falls below 0.9
without any change in the server (0.81 and 0.47 were seen before the
deadlines at c=64), so a failing verdict on one run would stop items for
the machine's load, not for the code. AGENTS.project.md already says a
pass/fail verdict comes only from tests and checks.

Options:
1. Keep bench.sh exiting 0 below the goal (today): the ratio is read by a
   person, with README's spread next to the goal.
2. Fail below the goal on one run: simple, but flaky on this machine at
   the spread measured.
3. Judge the goal on a quieter measure: the median of several interleaved
   rounds (about 1 minute per round per server), or the CPU time per
   request of lean-db against go-db (bench.sh already prints both), and
   fail on that. Costs gate time (option: interleaved rounds) or changes
   what the goal measures (option: CPU), which is the owner's call.

Recommendation: 1 now; 3 with CPU per request if a verdict is wanted,
since in fszibv's CPU rounds at a load average below 30 lean-db's CPU per
request at c=1 stayed within 36 to 39 µs while its throughput there ranged
from 10,906 to 12,242 req/s, and the throughput-only rounds at loads of 11
to 21 still put single ratios at 0.52 and 0.66; under heavier load CPU per request rose too (57 µs
at a load average of 33), so it is quieter, not immune.
