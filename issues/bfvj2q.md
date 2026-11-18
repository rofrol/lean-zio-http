Run the memory scenarios that wait on socket queues on Linux

Seen in item kaslrv: `bench/boundary`'s `held` (bench/boundary/main.go) still
skips on Linux the three scenarios with `lsofSettle` (400 connections holding
all but one byte of a maximum body; 100 connections holding a nearly maximum
head received 7 bytes at a time; 400 connections holding a request line with
8,176 empty query parameters). It prints "skipped: the socket queues it waits
on are read with lsof, on macOS only" in both runs of ./linux-check.sh. Item
kaslrv qualified `tcpQueues` on Linux (/proc/PID/net/tcp and tcp6, attributed
by socket inode, checked by `checkQueues`) for `memoryFull` only, as approved.
`awaitRead` polls `tcpQueues` up to 200 times.

Question: should these scenarios also run on Linux, on the qualified reading?
Options: enable them on Linux after `checkQueues`, checking `awaitRead`'s
polling against Rule 10 (it awaits the server's receive, an event the
queues show only by reading them) | leave them macOS only.

Decided 2026-11-18 by the coordinating session with sol, argon and hydrogen (consult round on bfvj2q; calls 37221e44, a0d63596, 23e30d8f; all three agree) under the user's delegation of 2026-11-18: approved with conditions. Enable the three scenarios on Linux only after checkQueues qualifies the inode-attributed reading for each of these workloads (client-to-server direction, up to 400 connections); memoryFull's qualification does not carry over. awaitRead's bounded read of /proc is external polling of kernel socket-queue state, which sends no notification; label it so next to `tries`, keep it bounded and a failure when exhausted, and add no sleep, delay or larger count without measured evidence. Rename the lsof-specific guard, names and error strings to match. State that a drained queue does not prove Conn.step processed the bytes. Check: both backends of ./linux-check.sh run the three scenarios instead of printing skipped.
