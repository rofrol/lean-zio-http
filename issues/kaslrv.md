Run the worst-case memory scenario on Linux

Seen in item byurlg: `bench/boundary`'s `memoryFull` (bench/boundary/main.go) reads socket queues with `lsof -T qs` and was checked on macOS only; on other systems it prints "skipped" (bench.sh supports Linux elsewhere, e.g. server CPU time from /proc). Linux exposes the same queues in /proc/net/tcp (tx_queue, rx_queue) or `ss -tn`.

Question: should the scenario read the queues on Linux too? Options: /proc/net/tcp | ss -tn | leave macOS only.
