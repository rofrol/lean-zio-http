# Running

Run everything (macOS or Linux; needs the Lean toolchain from
`lean-toolchain`, Zig 0.17, Go, PostgreSQL with `pg_config`, which
also provides libpq (Homebrew `postgresql@18`), and `bc`, without which
`bench.sh` stops at its start):

```sh
./bench.sh
```

It first checks that every relative link of the git-tracked Markdown files
names a tracked file or directory and that each anchor on a Markdown target
is the GitHub slug of one of its headings (`bench/mdlinks`, which prints
each broken link with its file, line and whether the path or the anchor
failed; no network). Then it builds all parts, runs the Lean tests
(`lsrv-test`: both adapters on the same requests, limits at their exact boundaries, Host and target
validation, `100-continue`, the response checks, and connections through
`Conn.step`, and that `zig/src/pg.c`'s result bound equals
`Query.maxResultBytes`), the module boundary check (`lsrv-arch`), a check that `zig/`
built for x86_64 Linux at the Lean toolchain's glibc references no libc
symbol that glibc lacks (and that the same build for glibc 2.41 does), that
on Linux a Lean toolchain without `lib/glibc/libc.so` fails the build
(`lake script run zsrv-target-check`), the parser comparison
(`lsrv-compare`), the boundary tests and the
end-to-end checks (the last two against both parsers), then measures both
parsers' cost per request in isolation (`lsrv-bench`, which prints each row
as it is measured) and each
server at 1, 64 and 256 connections for 10 s, printing requests per second,
latency percentiles and server CPU time per request; the Lean servers must
then stop gracefully on SIGTERM. Then it creates a private PostgreSQL
cluster under its temporary directory (a Unix socket there, no TCP
listener; any other PostgreSQL on the machine is not touched), runs
`bench/dbcheck` and measures `lsrv-db` against `bench/pgserver`. Any failure stops it with a nonzero status,
and every server it started is stopped on exit. A server that stops
answering keeps it from ending; that is a failure to trace, never a result.

`./bench.sh` first runs `./check.sh`: every build, test and check above,
without the measurements (and so without `lsrv-bench`, `dusty-hello`,
`bench/load`, `bench/goserver` and `bench/pgserver`). What `lsrv-bench`
measures is also checked, in `lsrv-test`: both parsers consume the same
bytes of each corpus sequence, and each fragmented request is answered after
its last receive as in one receive. Run `./check.sh` on its own while
editing; the whole `./bench.sh`, measurements included, is the gate for
integrating a change (item cxhvkb). Both scripts share their helpers and the
private cluster's setup through `bench/lib.sh`; `bench.sh` measures on a
fresh cluster after `check.sh`'s has been removed.

The H1 parse path as lsrv-arena drives it has a harness of its own, outside both scripts: `lsrv-parsebench` runs
HttpArena's baseline (`get.raw`, `post_cl.raw`, one request per receive) and
pipelined (16 gcannon requests in one receive) shapes through the adapter's
parses of each receive (`parse`) and through `Conn.step` with `App.Arena`
(`step`), printing nanoseconds and allocations per request; `lsrv-parsebench
SHAPE LEVEL RECEIVES` runs one loop for a profiler. `lsrv-test` checks that
each shape completes its requests and gets `200` with App.Arena's body
(`Corpus.arenaShapesCheck`). `bench/parse/profile.sh OUT m1|linux [SHAPE LEVEL
RECEIVES]` records a call-graph profile of that loop: with Instruments' Time
Profiler (`xctrace`) on the M1, or with `perf record -g` in
`linux/Dockerfile`'s image with perf added (`bench/parse/Dockerfile`). Its
figures and profiles are in
[Where H1's parse spends lsrv-arena's CPU](reports/h1-parse-profile.md).

With no arguments `lsrv-parsebench` then prints its `full` section: one
receive that fills a connection's buffer with a small request pipelined
(`Corpus.fullCases`, checked by `Corpus.fullCasesCheck` in `lsrv-test`),
timing the one `Conn.step` on it, the whole receive, and the suffix copies
that step makes. `bench/fairness/run.sh` measures the same case on the loop:
it starts `lsrv-arena` with one loop and times a probe connection's round
trips alone and beside a connection that keeps its buffer full (`ARENA`
names another build to measure, `PROBES` the round trips per run). Both
measure only, outside `check.sh` and `bench.sh`; their figures are in
[One step on a full buffer of pipelined requests](reports/full-buffer-step.md).

The boundary tests open thousands of loopback connections, and each closed
one stays in TIME_WAIT for 2*MSL (30 s on macOS) on the side that closed it
first. On the M1 the suite's two runs in one `check.sh` raised
the kernel's TCP PCB count (every TCP socket of the system) from about 800
to about 7,500; the ephemeral port range holds 16,384 ports. A third pair of
runs started at once after two others failed a dial with EADDRNOTAVAIL. So a `check.sh` or
`bench.sh` started within about 30 s of another connection-heavy run on the
same machine can fail for a reason that is not the change under test. Such a
failure stays a failure: the suite names EADDRNOTAVAIL as possible port
exhaustion, and `check.sh` prints the PCB count (system-wide, every TCP
socket) and the ephemeral port range before each run of the suite and after
a failing one, where `sysctl` has them.

`check.sh` runs `zig build test` against the one libpq `pg_config` names.
`./libpq-lines.sh PGSRC` runs it against every libpq line the pool supports
([Modules](modules.md), `zig/`: 17 or later): the lowest supported release
and the newest release of each line from 17 up, built from the release tags
of `PGSRC`, a git checkout of PostgreSQL
(`git clone https://git.postgresql.org/git/postgresql.git`), into a cache
outside the repository (`$LIBPQ_CACHE`, default
`~/.cache/lean-zio-http/libpq`). It checks that each run loaded the libpq it
built (`pg_glue_test` prints the file and the version it loaded) and prints
one line per release. It is opt-in, not part of `check.sh` (item oruxe4):
run it for every change to the PostgreSQL glue and at libpq updates. On
the M1 (2026-11-17, 10 releases from 14.6 to 18.7) the first run, building
every libpq, took 269 s, and a run on a warm cache 5 s; the cache holds
81 MB, the checkout 596 MB.

`./cleanup-controls.sh` checks the transport tests' cleanup
(`Single.deinit` in `zig/src/serve_test.zig`) with two negative controls
(`zig/src/cleanup_controls_test.zig`, run by `zig build cleanup-controls`):
a test that fails with connections open must fail with its own error, its
connections drained, and every test after it must pass; a test that passes
but leaves a connection open must be reported for the leak it logged at
error level (Zig 0.17.1's runner fails a passing test that logged an
error). The script checks those reports by name and the test counts, so a
compile error or any other failure fails it. It is opt-in, not part of
`check.sh` (item znorfg): run it at each update of Zig and for every change
to `Single.deinit`.

`./linux-check.sh` is the Linux validation (item ogcdwm): it builds the
Debian trixie image of `linux/Dockerfile` (Zig, the Lean toolchain of
`lean-toolchain` and Go at pinned versions and checksums; the base image
pinned by digest; PostgreSQL 17 as Debian's archive has it at the build)
with this machine's `docker` (on the M1, OrbStack) and runs the whole
`./check.sh` in it on a copy of the working tree: the transport's and the
pool's tests (`zig build test`), once on epoll and once on io_uring
(`LSRV_LINUX_BACKEND`; only that run turns the container's seccomp filter
off, as docker's default profile refuses `io_uring_setup`: acceptable for
this local developer container running the repository's own code, never
for production or for untrusted code), which serve_test.zig
checks is the backend in use, the database checks on the container's own private
cluster, and every other check. It prints the architecture, kernel, Debian,
Zig, Lean, Go, libpq, PostgreSQL and zio versions first, and fails when
libpq's or the server's major is not 17 or Zig is not on
`zig/build.zig.zon`'s `minimum_zig_version` line (the same major.minor,
and a patch at least the minimum's), so a rebuild that drifted fails instead of testing other
versions silently. To move the base image, take the index digest that
`docker buildx imagetools inspect debian:trixie` prints and note the date
beside it in `linux/Dockerfile`, and move the digest and date
of its copies in `bench/arena/local.Dockerfile` (the local HttpArena image)
and `bench/arena/gcannon.Dockerfile` (`bench/arena/build.sh`'s gcannon)
with them. It needs network access and
docker; `./check.sh` does not depend on it. Run it at each update of zio and
record its result in the commit. It is development evidence on the host's
architecture and the container runtime's kernel, not production
qualification: x86_64, kernel 6.12 and Debian 13's own kernel are not
covered by an OrbStack run; the suite's run on the deployed server's own
host is in [HttpArena on the VPS](reports/httparena-vps.md). Its last recorded result is in
`zig/src/serve_test.zig`'s header.

The scripts that build images on this machine's docker
(`./linux-check.sh`, `bench/arena/local.sh`, `bench/arena/build.sh`,
`bench/parse/profile.sh`) may run at once from several sessions and
worktrees against one daemon. Each run therefore tags its
images `NAME:run-…`, a tag of its own (`linux/run-images.sh`), runs those,
builds `bench/parse/Dockerfile` on its own base (`--build-arg BASE_IMAGE`),
and removes exactly those tags when it ends, also on SIGINT or SIGTERM (a
tag the daemon sets only after that cleanup, when the interrupt came as a
build was exporting its image, stays: `docker image ls '*:run-*'` lists
them); the download cache volumes stay shared, and docker's build cache
keeps a rebuild of unchanged Dockerfiles quick. No image is left tagged for later use: to
read a profile again, build the image as the script does.
`linux/run-images-test.sh` checks it with two overlapping runs whose
`linux/Dockerfile` differs by a marker, forced into the order that would
mix them up with a shared tag: each run's containers must report its own
marker, and each run's tags must be gone after it. Run it for every change
to how those scripts build or name images; it needs docker.
Three limits of this are accepted (decided 2026-11-19 by the coordinating
session on item amjip6): the tag the daemon sets after an interrupted
export, above, which is never another run's; when `docker image inspect`
fails because the daemon cannot be reached, the cleanup takes a tag as
absent and leaves it without a message (`docker image ls '*:run-*'` lists
it once the daemon is back); and when `mktemp` fails in one of
`linux/run-images-test.sh`'s two runs (a broken `TMPDIR`), the other run
waits until the test is interrupted.

`./bench.sh` runs in the same image (it has `bc`, which
`bench.sh` needs for the CPU per request and lean's share of Go).
`./linux-check.sh` runs only `./check.sh`; to measure in the container,
build the image and run `./bench.sh` on a copy of the tree, as
`linux-check.sh` does (epoll, the build's default; the measurements are of
the container on this machine, comparable only with each other):

```sh
docker build -t lsrv-linux-check linux
linux/tree-snapshot.sh /tmp/lsrv-files /tmp/lsrv-tree.tar &&
docker run --rm -e MDLINKS_FILES=/files -v lsrv-linux-cache:/home/check/.cache \
  -v /tmp/lsrv-tree.tar:/tree.tar:ro -v /tmp/lsrv-files:/files:ro lsrv-linux-check sh -c \
  'mkdir src && tar --warning=no-unknown-keyword -xf /tree.tar -C src && cd src && ./bench.sh'
```

The copy has no `.git`, so `bench/mdlinks` takes the list of its files
from `MDLINKS_FILES` instead of `git ls-files`. `linux/tree-snapshot.sh`
copies the files the working tree holds (a tracked file deleted but not
staged is left out; symlinks are kept); every container script copies the
tree with it, and `./check.sh` checks it (`linux/tree-snapshot-test.sh`).

`bench/boundary` starts the fixture server (`lsrv-fixture`, and
`lsrv-fixture-hand` with `-no-continue`) with the test settings and checks:
exact 60,001-byte responses through 7-byte operations, split and pipelined
requests, injected failures, 2,000 connections closed or reset at different
points, `100-continue` and a response over the bound, the graceful shutdown
with a response in flight and an idle and a partial connection, admission at
`--max-conns 2`, the two crash points, and the memory per connection
(measured; checked against a bound only while a response is sent, [Memory](memory.md)); every
accepted connection must be freed exactly once and the server must stop
with status 0.

`bench/dbcheck` starts `lsrv-db` with one loop for each test and checks,
without assumptions on elapsed time (a query waits on an advisory lock the
test holds; `pg_stat_activity` tells the test it is waiting): results, a
missing row and two chained queries; a slow query does not delay the loop's
other connections (a request with no query, and a query on the second
slot); pool exhaustion (one slot: 20 queries queue behind a waiting one,
which the server's `query` trace lines confirm, PostgreSQL sees one
connection, all complete once the lock is released); a
restart (`pg_ctl restart -m fast` with a query in flight, its lock held by a
prepared transaction so it cannot finish first: 503, then, once the
`pg closed` trace lines show both old sessions ended, 200 on fresh
connections on both slots); errors on one slot (a query that cannot be
prepared, a cached statement failing when executed, `BEGIN` leaving a
transaction open: each 500 with its SQLSTATE, and the slot answers the next
query); the database stopped (503, 200 once started); and SIGTERM with a
query waiting (once the `stop` trace line shows the shutdown started, the
lock is released: the query is answered, then `stopped` and status 0).

Reading the numbers: the load generator runs on the same machine, so at 64
and more connections it is the limit; compare the 1-connection rows and the
CPU per request. The servers differ in features and limits ([Production contract](production-contract.md)), and
closed-loop latency hides queueing under overload. The numbers exclude
connection setup: `bench/load` opens every connection with one warm-up
request before the clock starts (at the end of
[The dusty failure at 256 connections](reports/dusty-256-connections.md)); only the server CPU per request still
includes those warm-up requests, `bench.sh` samples it around the whole run,
at most 256 requests against hundreds of thousands. HttpArena's profiles on
Linux are in [HttpArena on the VPS](reports/httparena-vps.md).
