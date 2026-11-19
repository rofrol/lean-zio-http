#!/usr/bin/env python3
"""bench/arena/summarize.py OUT: the table of the HttpArena runs (item 53rwgc;
docs/reports/httparena-vps.md) from the out/ directory bench/arena/run.sh
bench wrote, copied off the host.

Per profile and server, over rounds 1-5 (round 0 is the warm-up): the median
and the range of throughput (2xx responses per second of the generator's
window), p99 latency, server CPU per response and peak memory (VmHWM of the
sample's own process), and totals of non-2xx answers, of responses slower
than 5 s (gcannon's "Latency overflow", outside its histogram, so a p99 near
5 s is a lower bound) and of zrk's errors (sockets, timeouts). gcannon
reports no other error: each response it counts is in its status counts, and
its reconnects in limited-conn are the profile's own (-r 10: a new connection
after every 10 requests), as HttpArena's gcannon.sh counts them, apart from
errors. CPU per response is approximate: the server's CPU is read around the
whole generator run, connection set-up and drain included (CLK_TCK 100).
"served" is gcannon's "Connections served" (gcannon-served.patch, item
dtlin3): the connection slots answered at least once in the measured window,
against the 4,096 configured, "-" for zrk and for a run with an unpatched
gcannon. p99.9 is gcannon's own, "-" for zrk, which reports none.
Prints Markdown. A difference is called resolved only where the two ranges do
not overlap.
"""
import json
import re
import statistics
import sys
from pathlib import Path

ORDER = ["lsrv-epoll", "lsrv-io_uring", "go-stdlib", "go-fasthttp"]
TICK_S = 0.01  # CLK_TCK on the VPS (getconf CLK_TCK: 100)


def gcannon(text):
    m = re.search(r"(\d+) requests in ([\d.]+)s, (\d+) responses", text)
    codes = dict(re.findall(r"(\dxx)=(\d+)", text))
    lat = re.search(r"Latency\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", text)
    over = re.search(r"Latency overflow \(>5s\): (\d+)", text)
    served = re.search(r"Connections served: (\d+)", text)
    ok = int(codes.get("2xx", 0))
    bad = sum(int(codes.get(k, 0)) for k in ("3xx", "4xx", "5xx"))
    return {
        "rps": ok / float(m.group(2)),
        "responses": int(m.group(3)),
        "p99_ms": ms(lat.group(4)),
        "p999_ms": ms(lat.group(5)),
        "bad": bad,
        "slow": int(over.group(1)) if over else 0,
        "errors": 0,
        # gcannon-served.patch's line; absent from an unpatched gcannon's output.
        "served": int(served.group(1)) if served else None,
    }


def zrk(text):
    j = json.loads(text)
    errors = sum(v for k, v in j["errors"].items() if k != "non_2xx_3xx")
    return {
        "rps": j["status_codes"]["2xx"] / j["duration_s"],
        "responses": j["requests"],
        "p99_ms": j["latency_us"]["p99"] / 1000,
        "p999_ms": None,
        "bad": j["errors"]["non_2xx_3xx"],
        "slow": 0,
        "errors": errors,
        "rate_ratio": j["rate_ratio"],
        "served": None,
    }


def ms(s):
    v = float(re.match(r"[\d.]+", s).group(0))
    return v * {"us": 0.001, "ms": 1, "s": 1000}[re.search(r"[a-z]+$", s).group(0)]


def rng(xs, fmt):
    return f"{fmt(statistics.median(xs))} ({fmt(min(xs))}-{fmt(max(xs))})"


def opt(xs, fmt):
    """rng, or "-" where the generator does not report the value."""
    return "-" if None in xs else rng(xs, fmt)


def main():
    out = Path(sys.argv[1])
    rows = {}
    for line in (out / "samples.txt").read_text().splitlines()[1:]:
        rnd, prof, srv, ticks, hwm, _t0, _t1 = line.split()
        if rnd == "0":
            continue
        text = (out / f"r{rnd}-{prof}-{srv}.txt").read_text()
        r = zrk(text) if prof.startswith("latency") else gcannon(text)
        r["cpu_us"] = int(ticks) * TICK_S * 1e6 / r["responses"] if r["responses"] else float("nan")
        r["hwm_mb"] = int(hwm) / 1024
        rows.setdefault(prof, {}).setdefault(srv, []).append(r)
    for prof, servers in rows.items():
        print(f"\n{prof}\n")
        print("| server | runs | req/s | p99 ms | p99.9 ms | CPU µs/resp | peak MB | non-2xx | over 5 s | zrk errors | served |")
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for srv, rs in sorted(servers.items(), key=lambda kv: ORDER.index(kv[0])):
            col = lambda k: [r[k] for r in rs]
            print(f"| {srv} | {len(rs)} | {rng(col('rps'), lambda v: f'{v:,.0f}')} "
                  f"| {rng(col('p99_ms'), lambda v: f'{v:.1f}')} "
                  f"| {opt(col('p999_ms'), lambda v: f'{v:.1f}')} "
                  f"| {rng(col('cpu_us'), lambda v: f'{v:.0f}')} "
                  f"| {rng(col('hwm_mb'), lambda v: f'{v:.0f}')} "
                  f"| {sum(col('bad'))} | {sum(col('slow'))} | {sum(col('errors'))} "
                  f"| {opt(col('served'), lambda v: f'{v:,.0f}')} |")
            if prof.startswith("latency"):
                print(f"<!-- {srv} rate_ratio {min(col('rate_ratio')):.4f}-{max(col('rate_ratio')):.4f} -->")


main()
