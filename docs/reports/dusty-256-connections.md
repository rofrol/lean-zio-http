# The dusty failure at 256 connections

Measured on 2026-11-16 on the M1 by the spike's item 2l6rcv (an
ekklesiai.org queue item; recorded here in ddcabe3); the fix is item
vma67w's. A historical record, kept as it was written and not updated as the
code changes; the current contracts are in the documents
[README.md](../../README.md#documentation) lists. Item ids name queue items;
`git log --grep ID` finds their commits.

Cause: on this machine (the M1, macOS) a listening socket holds at most 128
connections the server has not accepted yet, and in the experiment below the
connections past that were reset. The load generator dials all its
connections at once, so at 256 and 512 connections a server that does not
accept fast enough in the first milliseconds loses some to a reset, and the
run fails. It is not specific to dusty: Go fails the same way. The evidence
below is indirect (outcomes and timing, no packet trace), but every failure
seen matches it and none falls outside it.

Evidence (2026-11-16, diagnostic scripts outside the repository, not tests):

- Limit: `sysctl kern.ipc.somaxconn` is 128; dusty asks for that backlog
  (`src/server.zig:576-589` and `Listener.kernel_backlog` in
  `src/config.zig`, dusty 96e117f), Go's `net.Listen` asks for it too, and the
  Lean loop asks for 4,096 (`zig/src/serve.zig:472`). A Go program that
  listens with backlog 128, or with 4,096 through `listen(2)`, never accepts,
  and dials N connections at once that each send a byte and read: for N = 128
  all 128 wait in the queue; for N = 129, 160, 192, 256 and 512, exactly 128
  wait and the other 1, 32, 64, 128 and 384 get `read: connection reset by
  peer`. So macOS caps the backlog at 128 here, whatever is asked, and the
  connections past it fail with a reset (no packet trace shows how).
- Reproduction: 30 iterations of a fresh server, then `bench/load` at 64,
  256 and 512 connections for 3 s each. Failed runs out of 30:

  | server | c=64 | c=256 | c=512 |
  |---|---:|---:|---:|
  | dusty (3 accept loops, its default for 10 CPUs) | 0 | 7 | 19 |
  | dusty with `.acceptors = 8` | 0 | 5 | 13 |
  | go | 0 | 3 | 11 |
  | lean-zio (`lsrv 8`) | 0 | 0 | 0 |

  All 58 failed runs above ended with `read: connection reset by peer`,
  the form the queue experiment gives, or `connect: connection reset by
  peer`, which it did not give; that form was not traced further, but it
  came in the same runs and, in the timing runs below, in the same first
  milliseconds. dusty logs `Connection error:
  error.SocketUnconnected` (ENOTCONN) 200 times in its 30 iterations, fewer
  than its failed connections and none in some failing iterations: consistent
  with connections reset before dusty used them, not a cause of the
  failures.
- Timing: with the generator changed (outside the repository) to note when
  each connection failed, 12 runs of dusty at 512 connections for 2 s had
  their last failure 13 to 39 ms after the start, none later: the failures
  happened while the connections opened. This was measured at 512
  connections only.
- Not checked: `netstat -s -p tcp` prints 0 for every counter here, so the
  kernel's listen queue overflow counter could not confirm the drops.

What it means for the numbers: a run that passed had no reset, so these
resets did not bias dusty's or Go's numbers from runs that passed (the
caveats under "Reading the numbers" in [Running](../running.md) still apply to them). `bench.sh`
failed at 256 connections now and then for this reason (in the loop above,
about one run in four for dusty and one in ten for Go): of its two runs for
this item, the first passed and the second failed at dusty c=256 with
`read: connection reset by peer` on 4 connections. Why Lean's loop drains
the queue fast enough and dusty's does not was not traced: more accept loops
in dusty did not remove the failures.

The fix (item vma67w): `bench/load` now opens its connections before the
measurement. Each connection, with its own transport so that no other
request takes it over, sends one warm-up request and waits for its response,
the event that shows the server accepted it; at most 128 connections await
that first response at a time, and the clock starts once every connection
has answered. No delays or retries are involved, and the measured numbers
exclude connection setup. With it, the same 30-iteration loop (fresh server,
then 256 and 512 connections for 3 s; 2026-11-16) failed 0 of 30 runs at
each count for dusty (3 accept loops) and for Go, and a c=512 run held 512
established connections on both the generator's and Go's side.
