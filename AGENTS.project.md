# Rules of this repository

Read with `AGENTS.md` (the shared policy, copied verbatim from agent-kit);
these rules are specific to lean-zio-http.

## The queue runs through rr2

The user said on 2026-11-16 (ekklesiai.org's item m4jfmv) that this
repository has its own queue in `issues/`, run by rr2 as ekklesiai.org's is,
and that the queue items about the server move here:

- Run an item of "Next, in order" with `rr2 --issue ID < task.md`, or the
  queue item after item with `rr2 queue` (rr2's README, "Usage" and "The queue
  item after item"); rr2 runs the agent in its own worktree and integrates
  the result. A session does not do a queue item by hand in the main checkout.
- An rr2 run makes every change to this repository's files outside `issues/`;
  every change to `issues/` goes through `rr2 issue`. The coordinating
  session does only what acts outside the repository (publishing, pushing,
  opening an upstream issue) and changes `issues/` through `rr2 issue`. An
  item that acts outside the repository, changes `issues/`, or both, and
  changes no other file, carries the line `Done by: the coordinating session`
  after its title; that session does it and finishes it with
  `rr2 issue finish ID`.
- Change `issues/` only with `rr2 issue add|move|edit|finish`, never by hand.

## Architecture map

- What it is: a Lean 4 HTTP/1.1 server library on per-core zio.ev event loops
  (Zig, `zig/`), with non-blocking PostgreSQL access from the loops (libpq).
  The modules, their contracts and what each may import are in `README.md`,
  "Modules"; `Arch.lean` (`lsrv-arch`) enforces those import rules.
- Architectural core: the contracts `Server.Query`, `Server.Wire` and
  `Server.Handler`. Changing them changes every consumer.
- Consumers: ekklesiai.org pins this repository by commit
  (`require lsrv from git ... @ "<commit>"`); a change it needs is published
  here first, then its pin moves.
- Build: `lakefile.lean`; `extern_lib zsrv` builds `zig/` with `zig build`,
  traced on its files, the Lean and libpq include directories and
  `ZIG_OPTIMIZE`. Executables that run the transport add `-lpq`.
- Trust: the server parses untrusted network input (`Server.H1Adapter`,
  `Server.HandParser`) and talks to PostgreSQL through libpq with the
  consumer's connection string. It holds no secrets of its own.
- Persistent data: none; the example applications use a `world` table that
  `bench.sh` creates in a private, disposable cluster.

## Verification

`./bench.sh` (README, "Running"): builds everything, runs `lsrv-test`,
`lsrv-arch`, `lsrv-compare`, `lsrv-bench`, the Zig/Lean boundary tests, the
end-to-end checks against both parsers, the database checks on a private
PostgreSQL cluster, and the load measurements. Any failure stops it with a
nonzero status. It takes several minutes: run it as a visible job.
Measurements are comparative and machine-dependent; a pass/fail verdict comes
only from the tests and checks.
