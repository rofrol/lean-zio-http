# What the dependency assumptions rest on

Checked on 2026-11-19 at commit bccf77f (item jexowc), against the pinned
dependencies: zio f8ca47367765 (also zio's HEAD that day), the Lean
toolchain nightly-2026-11-17 (lean4 commit 55069db87ef1), the Lean
Reference Manual at reference-manual 02e5404 (it documents the latest
release, not the nightly), Zig 0.17.1, PostgreSQL 18.6 (Homebrew) on macOS
27.2 (M1). A historical record: it is not updated as the code or the pins
change.

Each assumption the comment audit found is classified as
`AGENTS.md`, Rule 6, asks: **documented** (an upstream passage, quoted),
**code only** (no upstream passage or maintainer statement found; the
pinned code is cited) or **measured**. "Not found" names the places
searched: zio's `README.md`, `DEVELOPMENT.md`, `docs/*.md` and
`src/ev/README.md`; zio's issues searched on GitHub for `LoopGroup`,
`loop group`, `sockreg`, `NetPoll` and `NetClose registration`, and the
issues opened from this repository; Lean's `doc/`, the Reference Manual and
lean4 pull request 3632.

## 1. `lean_initialize_thread` and `lean_finalize_thread` (zig/src/glue.c:12-19)

**Documented.** The Reference Manual, `Manual/Runtime.lean:507-513`
(section "Initialization" of the FFI chapter): "In addition, any other
thread not spawned by the Lean runtime itself must be initialized for Lean
use by calling `void lean_initialize_thread();` and should be finalized in
order to free all thread-local resources by calling
`void lean_finalize_thread();`". The manual documents the calls and when to
make them (it documents the latest release, not this nightly), and names no
header that declares them. The toolchain's headers do not (no match under
its `include/`); libleanrt exports both with C linkage (`nm` of
`lib/lean/libleanrt.a`; lean4 55069db87ef1 `src/runtime/thread.h:239-241`,
"thread initializer pair, for reverse FFI", from pull request 3632, whose
description reads "Makes it possible to properly allocate and free
thread-local runtime resources for threads not started by Lean itself").
`glue.c`'s declarations, `void f(void)`, match that signature. So the calls
are documented; that they must be declared by hand, and with which
signature, is checked against the pinned runtime only.

## 2. Accept callbacks run on their own loop's thread (zig/src/serve.zig:1329-1350)

**Code only.** zio's documentation says "Called on the loop's thread"
(`src/ev/completion.zig:294`) and nothing about which loop's when loops
are grouped or not. The pinned code: a loop given no `loop_group` uses its
own `internal_loop_group` (`src/ev/loop.zig:559-563`); the socket table is
"shared by every loop in a group" (`src/ev/sockreg.zig:105`); a parked op
is serviced and completed by the owning loop (`src/ev/sockreg.zig:213-271`,
`service` at 276-315). The changelog says only that the owning loop's
`service()` may finish an op "on another thread" when loops are grouped
(`docs/changelog.md:566-568`). No maintainer statement found. The
existing guards stay as they are: serve_test.zig checks that `startLoop`
leaves its loop in its own group and that the transport's sources name no
`loop_group`, and `pg.ownLoop` panics when a callback comes from another
loop.

## 3. The pool polls a duplicate of libpq's socket (zig/src/pg.zig:60-71)

**Code only.** No documentation or maintainer statement found that a
socket registration lasts until a `NetClose` or that closing a descriptor
with an op parked on it is forbidden. The pinned code:
`src/ev/sockreg.zig:20-22` ("Entries are keyed by fd and live until the
socket is closed"); `unregister`, `src/ev/sockreg.zig:357-375`, asserts that
no op is parked on either direction ("The contract is that callers cancel
or await outstanding socket ops before closing the fd"); `NetClose` calls
it on kqueue (`src/ev/backends/kqueue.zig:634-641`) and epoll
(`src/ev/backends/linux/epoll.zig:609-616`). The io_uring backend keeps no
such table. pg.zig's comment now cites these lines.

## 4. Readiness by a peeking receive instead of `NetPoll` (zig/src/pg.zig:192-202)

**Measured**, on macOS only for the server. On kqueue and epoll, `NetPoll`
probes with `poll(2)` on the one descriptor with a zero timeout
(`src/ev/sockreg.zig:431-450`) and, once parked,
completes from the readiness event without probing again
(`src/ev/backends/kqueue.zig:1092-1102`,
`src/ev/backends/linux/epoll.zig:1025-1045`); the peeking `NetRecv` probes
with `recv` and, once parked, runs `recv` again on the event (`service`,
`src/ev/sockreg.zig:276-315`, through `checkCompletion`:
`src/ev/backends/kqueue.zig:899-915`; `src/ev/backends/linux/epoll.zig:871`, the
`.net_recv` arm of its `checkCompletion`). So a wait that
parks costs the peek two receives and `NetPoll` one `poll(2)`, and one that
finds data at once one of each. Which costs the server more also depends on
how often a wait parks, which was not counted.

- `poll(2)` on one descriptor with a zero timeout against
  `recv(fd, buf, 1, MSG_PEEK)` on a nonblocking AF_UNIX
  stream socket, 2,000,000 calls each, three repetitions (a C loop, not
  kept in the repository): on macOS (M1) `poll` 7,271 to 7,740 ns with
  nothing to read and 546 to 555 ns with a byte waiting, the peek 259 to
  262 ns with nothing to read and 293 to 332 ns with a byte waiting; in the
  Linux container (`linux/Dockerfile`'s image, OrbStack,
  kernel 7.2.12, aarch64) `poll` 151 to 158 ns and the peek 145 to 156 ns
  either way.
- `lsrv-db` built twice from bccf77f, once as it is and once with
  `rpoll` as `ev.NetPoll.init(self.fd, .recv)` (nothing else changed), both
  running on one private cluster (8 loops with 4 connections each),
  `GET /db?id=42`, eight interleaved rounds of 10 s per server and
  concurrency, the order alternating each round, on the shared M1 (load
  average 8 to 22): the server CPU time per request was lower with the peek
  in 8 of 8 rounds at 64 connections and in 7 of 8 at one; on this machine
  the medians were 40.6 against 50.3 µs at 64 connections and 35.9 against
  37.7 µs at one; requests per second, medians, 75,554 against 59,997 and
  12,208 against 10,270. The figures, round by round, are in
  [PostgreSQL measurements](postgresql-throughput.md#2026-11-19-the-peeking-receive-against-netpoll-item-jexowc).

So on this M1, for this query, the peek costs the server less, as the
2026-11-16 single runs found, and the microbenchmark is consistent with
`poll(2)` being the reason (it does not prove it). In the Linux container
(an OrbStack VM on the same M1, AF_UNIX sockets only) the comment's premise
did not hold: `poll(2)` cost about what a receive cost (overlapping
ranges in this microbenchmark), so on epoll `NetPoll`
might save a receive per parked wait; on io_uring `NetPoll` is a
`POLL_ADD` (`src/ev/backends/linux/io_uring.zig:815-824`). No server
comparison was run on Linux (in a container, on bare metal or on x86-64),
and the M1 comparison used the cluster's Unix socket, not a TCP connection
to the database.

2026-11-20 (item g62mok): the same server comparison in that container
(OrbStack, aarch64, the shared M1 under load), on epoll and on io_uring,
ten interleaved rounds each, did not observe the M1's gap: the medians of
the server CPU time per request differed by less than 1 µs (at most 2.3%)
in both directions, 23.25 against 23.25 µs on epoll and 22.8 against
22.55 µs on io_uring at 64 connections; only at one connection on io_uring
did one probe win most rounds (the peek, 8 of 10, its median 0.85 µs
lower). Preliminary (a VM on a loaded host); the
VPS, bare metal and x86-64 were not measured. The figures are in
[PostgreSQL measurements](postgresql-throughput.md#2026-11-20-the-peeking-receive-against-netpoll-in-the-linux-container-item-g62mok).

## 5. `test/retained.c` declares `calloc`, `realloc`, `abort` and `mi_usable_size` (test/retained.c:13-25)

- `abort`: **documented** by the C standard (C11 7.1.4p2): "Provided that
  a library function can be declared without reference to any type defined
  in a header, it is also permissible to declare the function and use it
  without including its associated header."
- `calloc`, `realloc`: **code only**. They refer to `size_t`, a type
  defined in a header, so 7.1.4p2 does not cover them; they work because
  the toolchain links a libc whose functions have these signatures, and
  `lean.h` itself declares `malloc` and `free` the same way ("avoid
  including big `stdlib.h`", `include/lean/lean.h:524` and 582). `stdlib.h`
  was not found under the toolchain's `include/`; whether the compiler finds
  one elsewhere (a system SDK) was not checked.
- `mi_usable_size` and Lean objects being mimalloc blocks: **code only**.
  The toolchain's own headers say it is built with mimalloc:
  `include/lean/config.h:10` defines `LEAN_MIMALLOC`, and `lean.h` then
  includes `lean/mimalloc.h`, which declares `mi_usable_size` (line 133) —
  so the hand declaration repeats one `lean.h` already makes. That the
  objects the test measures (constructors, arrays, strings, byte arrays;
  not persistent or compacted objects, which it skips or does not meet)
  are pointers to the start of their mimalloc block rests on code:
  `lean_alloc_small_object` (`include/lean/lean.h:527-548`) returns
  `mi_malloc`'s pointer above `MI_SMALL_SIZE_MAX` and otherwise
  `lean_alloc_small_object_core`'s, which is `mi_theap_malloc_small`'s
  (lean4 55069db87ef1 `src/runtime/mimalloc.cpp:39-52`); `lean_alloc_object`,
  which arrays, strings and byte arrays use, returns `mi_malloc`'s
  (`src/runtime/object.cpp:365-378`). The release notes of v4.35.0 say only
  that `mimalloc.cpp` "contains our object allocation logic"
  (`Manual/Releases/v4_35_0.lean:401`). No passage documents the object
  layout against the allocator.

## 6. The toolchain's glibc version read from `libc.so` (lakefile.lean:19-71)

**Code only** for what the code reads. That the toolchain ships glibc as
`lib/glibc/libc.so` without the version in the name rests on lean4
55069db87ef1 `script/prepare-llvm-linux.sh:59-64` ("glibc: use for linking
(so Lean programs don't embed newer symbol versions)"; the copy to
`${b%-*}.so`). What is documented is the floor: the Reference Manual,
`Manual/SupportedPlatforms.lean:28-29`, lists as Tier 1 "`x86-64` Linux
with glibc 2.26+" and "`aarch64` Linux with glibc 2.27+". That is a
statement of the platforms Lean supports, not of the glibc the toolchain
links against, so it does not establish the Zig target `zsrvTarget` needs;
what `zsrvTarget` infers comes from the version names the shipped library
defines.

## Outcome

Documented: 1's calls (their hand declaration is checked against the pinned
runtime only), 5's `abort`. Measured: 4 (the peek costs less on the M1;
in the Linux container the syscalls cost about the same; no server
comparison on Linux). Code only: 2, 3, 5's `calloc` and `realloc` and the Lean objects being
the start of their mimalloc blocks, 6. The code-only points go to the owner
for a decision (approve a supported-subset contract, ask upstream, or stop
relying on it); no behaviour was changed.

2026-11-20 (item alblg3): the code-only points 2, 3, 5 (`calloc`,
`realloc`, the objects' layout) and 6 were approved as supported-subset
contracts, recorded in `AGENTS.project.md`, "Supported-subset contracts";
`test/retained.c` now takes `mi_usable_size` from `lean.h`.
