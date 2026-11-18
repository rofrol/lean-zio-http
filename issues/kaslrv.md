Run the worst-case memory scenario on Linux

Seen in item byurlg: `bench/boundary`'s `memoryFull` (bench/boundary/main.go) reads socket queues with `lsof -T qs` and was checked on macOS only; on other systems it prints "skipped" (bench.sh supports Linux elsewhere, e.g. server CPU time from /proc). Linux exposes the same queues in /proc/net/tcp (tx_queue, rx_queue) or `ss -tn`.

Question: should the scenario read the queues on Linux too? Options: /proc/net/tcp | ss -tn | leave macOS only.

Recommendation (consult round 20261116-183449-f682, sol, under the user's delegation of 2026-11-16): decide with 53rwgc; leave /proc/net/tcp against ss open until namespace visibility and attribution to the server's sockets are established on a Linux machine.
Question: Should the scenario read the socket queues on Linux too, once a Linux machine is available?
Options: yes, decided with 53rwgc | leave macOS only

Checked 2026-11-17 with sol (consult round 20261117-011832-74e7) under the user's delegation: deferred until an authorized Linux machine (53rwgc) and evidence of socket attribution and namespace visibility; then choose /proc/net/tcp or ss.

Decided 2026-11-18 by the coordinating session with sol, argon and hydrogen (consult round 20261118-181941-5f8f; calls 4a23f520, e4c9a8ea, 272fc555), under the user's delegation of 2026-11-18 to decide the remaining open questions with the models: approved (sol and argon; hydrogen asked for a non-production Linux host, which the local container is): qualify /proc/net/tcp in the local Linux container (linux/Dockerfile's image), never on vps.frolow.dev. Read the server's network namespace, match established socket inodes to the server's file descriptors, and check the figures against a controlled set of connections before memoryFull reports queues on Linux. If attribution cannot be established, keep Linux reported as skipped and record why.
