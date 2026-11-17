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
  traced on its files, the Lean and libpq include directories,
  `ZIG_OPTIMIZE` and the Zig target (on Linux, the glibc of Lean's
  toolchain: `zsrvTarget`). Executables that run the transport add `-lpq`.
- Trust: the server parses untrusted network input (`Server.H1Adapter`,
  `Server.HandParser`) and talks to PostgreSQL through libpq with the
  consumer's connection string. It holds no secrets of its own.
- Persistent data: none; the example applications use a `world` table that
  `bench.sh` creates in a private, disposable cluster.

## Verification

`./bench.sh` (README, "Running"): builds everything, runs `lsrv-test`,
`lsrv-arch`, `lsrv-compare`, the PostgreSQL pool's and the
transport's tests (`zig build test` in `zig/`, README "PostgreSQL" and
"Production contract"), the Zig/Lean boundary tests, the
end-to-end checks against both parsers, the database checks on a private
PostgreSQL cluster, and the measurements (`lsrv-bench`, then the load
runs). Any failure stops it with a
nonzero status. It takes several minutes: run it as a visible job.
Measurements are comparative and machine-dependent; a pass/fail verdict comes
only from the tests and checks.

`./check.sh` runs the same builds, tests and checks without the
measurements; `./bench.sh` runs it first. `lsrv-bench` only measures; the
correctness of what it measures is checked in `lsrv-test` (item 6zs4mr). Use `./check.sh` while editing;
the whole `./bench.sh` stays every item's gate before it ends (decided
2026-11-17, item cxhvkb).

`./libpq-lines.sh PGSRC` (README, "Running") runs `zig build test` against
the lowest supported and the newest release of every supported libpq line,
not only the one `pg_config` names. Run it for every change to the
PostgreSQL glue (`zig/src/pg.c`, `zig/src/pg_glue_test.c`) and at each
update of libpq; it is not part of every item's gate (decided 2026-11-17,
item oruxe4; whether it joins the gate is a later decision on its measured
time and disk use).
The PostgreSQL checkout it takes as PGSRC lives at
`${XDG_CACHE_HOME:-~/.cache}/lean-zio-http/postgresql`, next to the script's
libpq cache; `git -C` it `fetch --tags` before a run, and clone
`https://git.postgresql.org/git/postgresql.git` there only when it is missing.

`./linux-check.sh` (README, "Running") runs the whole `./check.sh` in a
Debian container (`linux/Dockerfile`; on the M1, OrbStack's arm64 VM),
twice, so the transport's and the pool's tests run on epoll and on io_uring
(item wi7efy). Run it at each update of
zio and update the record of its last run in `zig/src/serve_test.zig`'s
header; `./check.sh` does not depend on it (decided 2026-11-17, item
ogcdwm). It is development evidence, not production qualification.

`./cleanup-controls.sh` (README, "Running") runs the negative controls of
the transport tests' cleanup (`Single.deinit`, `zig/src/serve_test.zig`).
Run it at each update of Zig and for every change to `Single.deinit`; it is
not part of `./check.sh` (decided 2026-11-17, item znorfg).
