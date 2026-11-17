Set TCP_NODELAY on the listening socket, not on each accepted one (zio issue 926)

The user pointed on 2026-11-17 to the maintainer's answer to our report https://github.com/lalinsky/zio/issues/926 (https://github.com/lalinsky/zio/issues/926#issuecomment-6942382039, lalinsky, 2026-11-17): "zio's own accept path no longer calls `setsockopt` on accepted sockets ... Since #870, which is in 9bef33d, `TCP_NODELAY` is set once on the listening socket and accepted connections inherit it. So the warnings you're seeing come from `zig/src/serve.zig:475` ... If you set `TCP_NODELAY` on the listener next to `SO_REUSEADDR` and drop the per-connection call, the warnings go away, and you save a syscall per connection." He will also make zio's typed option helpers return a proper error instead of logging EINVAL as unexpected.

Do:
- In zig/src/serve.zig set TCP_NODELAY on the listener next to SO_REUSEADDR and remove the per-connection `net.setNoDelay(fd, true) catch {}` (now line ~412). Quote the maintainer's statement next to the code as the basis (policy Rule 6).
- Test that an accepted connection has TCP_NODELAY set (getsockopt on the accepted fd) on macOS; note Linux as unverified until a Linux run (53rwgc).
- bench/boundary/main.go counts "zio EINVAL warnings" (zioShutWarning, line 45) as expected in the churn scenario: the churn scenario should now see none, so make it require zero, and update README where it calls them expected.
- Full ./bench.sh as the gate.
Approved 2026-11-17 by the coordinating session: the user brought the maintainer's answer; small, reversible, follows the maintainer's documented advice.
