Run libpq-lines.sh against the libpq 17+ lines after the chunked-rows change (4lmjda)

AGENTS.project.md says to run `./libpq-lines.sh PGSRC` for every change to
the PostgreSQL glue. Item 4lmjda (commit "Collect PostgreSQL rows in chunks
with libpq 17 as the minimum") changed zig/src/pg.c and pg_glue_test.c and
the script's supported lines (17 up), but no PostgreSQL git checkout was on
the machine, so the script itself was not run. What was run instead:
`zig build test` against the cached builds of libpq 17.0, 17.12, 18.0 and
18.7 under ~/.cache/lean-zio-http/libpq (each loaded library checked: all
passed) and 16.16 (pg.c does not compile, as intended); the script's
release-selection awk was checked on sample tag lists.

Question: run the script once with a fresh PostgreSQL checkout (`git clone
https://git.postgresql.org/git/postgresql.git`, about 600 MB) to confirm the
whole script on the 17+ lines, or accept the direct runs above?
Options: run it now (needs the checkout) | accept the direct runs until the next libpq update

Decided 2026-11-17 by the coordinating session: run it now. The premise was wrong: a PostgreSQL checkout exists at ~/.cache/lean-zio-http/postgresql, the one 3jnkx5's gate passed to libpq-lines.sh. Run `./libpq-lines.sh ~/.cache/lean-zio-http/postgresql` (`git -C ... fetch --tags` first) on main and record the per-release lines in the finishing commit. If a release fails, find the cause before anything else. Also make AGENTS.project.md name where the checkout lives (as a generic cache path, not a user path) so the next run finds it.
