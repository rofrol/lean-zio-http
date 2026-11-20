Fail zsrvTarget's Linux build when the Lean toolchain has no lib/glibc/libc.so instead of building for the host

Found by item alblg3 (commit 364e1f8, diff review round 20261120-163407-dd2c, raised by both sol and hydrogen): lakefile.lean's zsrvTarget links zsrv against the toolchain's lib/glibc/libc.so on Linux, a supported-subset contract now listed in AGENTS.project.md "Supported-subset contracts". If a toolchain update moves or drops that file, nothing detects it: zsrvTarget silently builds the library for the host instead. On macOS the file does not exist and the host build is intended, so the check would apply to Linux only.

Proposed: on Linux, make zsrvTarget fail with a message naming the missing path and the contract, and test it by pointing it at a toolchain directory without the file. Small, local, no dependency.
