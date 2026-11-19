Retire or record the local workarounds in the HttpArena build: the Rosetta zig wrapper and the gcannon patch

Found by the comment audit the user asked for on 2026-11-19:
- bench/arena/build.sh:55-67: a "zig" wrapper first on PATH rewrites -Dtarget=native-* to x86_64-* because the image's x86_64 Zig stops under Rosetta on OrbStack ("rosetta error: bss_size overflow"); no upstream report or documentation is cited (Rule 6: a third-party bug is never worked around locally; one no fork can reach goes to the owner).
- bench/arena/gcannon.Dockerfile:22-25 applies bench/arena/gcannon-served.patch to gcannon at a pinned commit: a change to third-party code built from our tree, not recorded as a fork (no docs/forks.md) and not offered upstream.
- bench/arena/gcannon.Dockerfile:10 chose its build path around an OrbStack "cannot overwrite digest" failure, uncited.
The owner decides: report each upstream, move the patch to a fork with a ledger entry, or build on a host without these limits (2ltibq's dedicated Linux machine would remove the Rosetta path).

Sol and hydrogen (consult round 20261119-075953-d7f4, 2026-11-19) both left this to the owner: it needs an outward action, a fork or another host.
Question: How should the HttpArena build stop relying on the Rosetta zig wrapper and the gcannon patch?
Options: build on 2ltibq's Linux host and drop the wrapper, keep the patch as a recorded fork in docs/forks.md | report the Rosetta failure upstream and offer the patch to gcannon (outward, your go) | keep both as they are, recorded as accepted by you
Checked: bench/arena/build.sh:55-67, gcannon.Dockerfile:10,22-25; no docs/forks.md exists.
