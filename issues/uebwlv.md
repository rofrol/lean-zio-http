Force the parked send in the drain tests with the Unix-domain helper

Follow-up of 3jnkx5 (commit c7afffb), whose report says the drain tests in `zig/src/serve_test.zig` assume, as the TCP tests did, that a send stays parked in the kernel when the drain ends. se4hhx showed that on loopback TCP that holds only by chance: the server's parked send keeps gaining room asynchronously, since the client's requested SO_RCVBUF of 4096 read 314352 on macOS. se4hhx added a deterministic way: a connected Unix-domain pair whose client never reads (`Listener.openUnix`, `Single.initOn`), with `conn.polling` as the positive event that the send is parked.

Work: wherever a drain test needs a send in flight when the drain ends, use that helper, wait for the positive event before the drain expires, and require the outcome that depends on it. Check that dropping the drain's close of a parked send in serve.zig makes the test fail. Test-only; no serve.zig change.
