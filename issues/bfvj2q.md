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
