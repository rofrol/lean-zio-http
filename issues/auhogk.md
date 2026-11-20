Explain the map_update_elem EEXIST warning at trace.bt's accept histogram

Seen while verifying item 6lqxi5 (not caused by it): two runs of
`PERF=1 bench/arena/local.sh OUT ARENA 1` in local.Dockerfile's container
(bpftrace 0.23.2, OrbStack's arm64 VM on the M1) put this into one trace
each, once before item 6lqxi5 changed `bench/arena/trace.bt` and once after:

```
/s/trace.bt:33:18-26: WARNING: File exists
Additional Info - helper: map_update_elem, retcode: -17
    @accept_ms = hist($d);
```

(traces `trace-go-fasthttp-pipelined-1.txt` and
`trace-go-fasthttp-baseline-1.txt`; the line number is the probe
`kretprobe:inet_csk_accept`'s `@accept_ms = hist($d)`.) The cause is not
traced: whether the update that failed dropped one accept from
`@accept_ms` (and whether `@accepted`, `@over_1s`, `@over_5s` or `@max_ms`
lose a count the same way), which would bear on the accept figures
`docs/reports/over-5s-tail.md` reports. The summary line does not read
`@accept_ms`, and the warning lands in the trace file beside the maps.

Options: (a) trace the cause (bpftrace's code generation for hist on a
first insert from two CPUs at once, at the pinned 0.23.2) and, if counts
can be lost, change trace.bt so they cannot, or make local-inner.sh fail
a sample whose trace holds a helper warning; (b) record it as a known
limit of the diagnostic in the report.

Approved by the models under the user's delegation of 2026-11-20 to decide the queue (consult round 20261120-201420-8ae4; sol call 47866e82, hydrogen call de487da4), both agreeing: option (b), state in the report that the warning appeared and that whether accept counts are lost is unverified; do not change the probes or reject samples on two warnings. Reopen if it recurs in a run the report's conclusions rest on.
