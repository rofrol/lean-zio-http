Run the worst-case memory scenario on Linux

Seen in item byurlg: `bench/boundary`'s `memoryFull` (bench/boundary/main.go) reads socket queues with `lsof -T qs` and was checked on macOS only; on other systems it prints "skipped" (bench.sh supports Linux elsewhere, e.g. server CPU time from /proc). Linux exposes the same queues in /proc/net/tcp (tx_queue, rx_queue) or `ss -tn`.

Question: should the scenario read the queues on Linux too? Options: /proc/net/tcp | ss -tn | leave macOS only.

Recommendation (consult round 20261116-183449-f682, sol, under the user's delegation of 2026-11-16): decide with 53rwgc; leave /proc/net/tcp against ss open until namespace visibility and attribution to the server's sockets are established on a Linux machine.
Question: Should the scenario read the socket queues on Linux too, once a Linux machine is available?
Options: yes, decided with 53rwgc | leave macOS only
