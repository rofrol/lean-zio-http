Report to zio that a queued connection reset by the peer is accepted successfully on Linux and macOS, against its accept documentation
Done by: the coordinating session

Requested by the user on 2026-11-19, after reading zio PR https://github.com/lalinsky/zio/pull/935 ("no platform gives a reliable way to make accept fail inline with ConnectionAborted"): open an issue at lalinsky/zio with a small C program as the reproducer.

Checked: a client completes the handshake, resets (SO_LINGER 0, close), then the server accepts. Linux 7.2.12 (OrbStack): accept succeeds, SO_ERROR 104 (ECONNRESET), read 0. macOS 27.2: accept succeeds, SO_ERROR 54, read 0. zio's src/net.zig (Server.accept's doc: "aborted or reset by the peer") and src/os/net.zig (errnoToAcceptError's comment: "A queued connection that went away before we took it is ECONNABORTED on POSIX") describe a reset in the queue as ConnectionAborted. This repository does not depend on it (zig/src/serve.zig uses net.accept, not Server.accept).
