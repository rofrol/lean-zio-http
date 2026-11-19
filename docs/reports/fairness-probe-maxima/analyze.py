"""Correlate the probe's slow round trips with the traced server loop (item
srx6tz, docs/reports/fairness-probe-maxima.md). Standard library only.

analyze.py PROBE.txt SERVER.bin [THRESHOLD_US] [SHOW]

Probe lines (bench/fairness -trace): send written recv gap gapAt, in ns of
the wall clock (gap: the -spin probe's largest pause between two polls, 0
without -spin).
Server events (trace.patch, 80 bytes each): kind id n w0 w1 c0 c1 v0 v1 i0
i1: kind 1 kevent (id 1: zero timeout; n events), 2 recvCb, 3 sendCb,
4 readyCb, 5 timerCb, 6 pollCb, id the connection; w the wall clock and c
the loop thread's CPU clock (ns) at the event's start and end; v and i the
process's voluntary and involuntary context switches there.

The probe connects last, so its connection has the highest id; the script
checks that this connection took one receive per sample (plus at most one,
the close), so each request arrived in one receive callback. A sample is matched to the probe connection's first receive
callback ending after the sample's write returned; its response is sent
inside that callback (Conn.startSend tries the send at once). Samples the
trace cannot place (no such callback, or the callback ending after the
probe's read ended, or the write's return falling outside the trace) are
counted and left out of every share.

For each matched sample slower than the threshold, from the write's return
to the end of that callback:
  srv_cpu   the loop thread's CPU time over that span (steps, kevent, zio
            between them), from the CPU clock at event boundaries, linearly
            interpolated at the write's return;
  srv_off   the span's wall time less srv_cpu: the loop thread not running
            (preempted, blocked, or waiting in kevent);
  kev_wait  the wall time of the span inside kevent calls with a timeout,
            which may block (it may include their CPU time);
  post      from the callback's end to the end of the probe's read;
  pre       from before the probe's write to its return.
"""
import bisect
import struct
import sys

KIND = {1: "kevent", 2: "recv", 3: "send", 4: "ready", 5: "timer", 6: "poll"}
REC = "<IIQqqqqqqqq"
SZ = struct.calcsize(REC)

probe = [tuple(map(int, l.split())) for l in open(sys.argv[1])]
raw = open(sys.argv[2], "rb").read()
assert len(raw) % SZ == 0, "not a whole number of 80-byte events"
ev = [struct.unpack_from(REC, raw, o) for o in range(0, len(raw), SZ)]
thr = int(sys.argv[3]) * 1000 if len(sys.argv) > 3 else 3_000_000
show = int(sys.argv[4]) if len(sys.argv) > 4 else 0
starts = [e[3] for e in ev]
conns = sorted({e[1] for e in ev if e[0] == 2})
pid = conns[-1]
probe_recvs = [e for e in ev if e[0] == 2 and e[1] == pid]
assert len(probe) <= len(probe_recvs) <= len(probe) + 1, f"connection {pid} took {len(probe_recvs)} receives for {len(probe)} samples"
pr_ends = [e[4] for e in probe_recvs]

rtt = sorted(s[2] - s[0] for s in probe)
q = lambda f: rtt[int(f * (len(rtt) - 1))] / 1e3
print(f"samples {len(probe)}: p50 {q(.5):.0f} p99 {q(.99):.0f} p99.9 {q(.999):.0f} max {rtt[-1]/1e3:.0f} us; "
      f"> {thr/1e6:.1f} ms: {sum(r > thr for r in rtt)}; server events {len(ev)}, probe connection {pid}")
cb = [e for e in ev if e[0] != 1]
print("  largest callback thread CPU (us):", sorted((round((e[6] - e[5]) / 1e3) for e in cb), reverse=True)[:5])
print("  largest kevent thread CPU (us):", sorted((round((e[6] - e[5]) / 1e3) for e in ev if e[0] == 1), reverse=True)[:3])
# Intervals (one event, or the gap between two events) in which the loop
# thread was off the CPU for more than 1 ms in all, outside blocking kevent
# calls; one interval may hold several pauses.
off = []
for a, b in zip(ev, ev[1:] + [None]):
    off.append(((a[4] - a[3]) - (a[6] - a[5]), a, "in " + KIND[a[0]], a[8] - a[7], a[10] - a[9]))
    if b is not None:
        off.append(((b[3] - a[4]) - (b[5] - a[6]), a, "after " + KIND[a[0]], b[7] - a[8], b[9] - a[10]))
off_big = [o for o in off if o[0] > 1_000_000 and not (o[2] == "in kevent" and o[1][1] == 0)]
print(f"  intervals with the loop thread off the CPU > 1 ms outside a blocking kevent: {len(off_big)}, "
      f"{sum(o[0] for o in off_big)/1e6:.1f} ms in all; voluntary/involuntary switches in them: "
      f"{sum(o[3] for o in off_big)}/{sum(o[4] for o in off_big)}")


def cpu_at(t):
    """The loop thread's CPU clock at wall time t, interpolated between
    event boundaries; None outside the trace."""
    k = bisect.bisect_right(starts, t) - 1
    if k < 0:
        return None
    e0 = ev[k]
    if e0[4] >= t:
        return e0[5] + (t - e0[3]) / max(1, e0[4] - e0[3]) * (e0[6] - e0[5])
    if k + 1 >= len(ev):
        return None
    nxt = ev[k + 1]
    return e0[6] + (t - e0[4]) / max(1, nxt[3] - e0[4]) * (nxt[5] - e0[6])


slow = [(s[2] - s[0], i) for i, s in enumerate(probe) if s[2] - s[0] > thr]
tot = {"srv_cpu": 0, "srv_off": 0, "kev_wait": 0, "post": 0, "pre": 0}
T = 0
unplaced = 0
pg_over = 0
matched = 0
for r, i in sorted(slow, reverse=True):
    send, written, recv, gap, gap_at = probe[i]
    j = bisect.bisect_left(pr_ends, written)
    c_at = cpu_at(written)
    if j >= len(probe_recvs) or c_at is None or probe_recvs[j][4] > recv:
        unplaced += 1
        if show:
            show -= 1
            print(f"  #{i} rtt {r/1e6:.2f} ms: not placed in the trace")
        continue
    rc = probe_recvs[j]
    span = rc[4] - written
    cpu = rc[6] - c_at
    kw = 0
    m = max(0, bisect.bisect_right(starts, written) - 1)
    while m < len(ev) and ev[m][3] < rc[4]:
        e = ev[m]
        if e[0] == 1 and e[1] == 0:
            kw += max(0, min(e[4], rc[4]) - max(e[3], written))
        m += 1
    post = recv - rc[4]
    matched += 1
    T += r
    tot["pre"] += written - send
    tot["srv_cpu"] += cpu
    tot["srv_off"] += span - cpu
    tot["kev_wait"] += kw
    tot["post"] += post
    if gap > 1_000_000:
        pg_over += 1
    if show:
        show -= 1
        print(f"  #{i} rtt {r/1e6:.2f} ms: write {(written-send)/1e3:.0f} us, server span {span/1e6:.2f} ms "
              f"(thread CPU {cpu/1e6:.2f}, not running {(span-cpu)/1e6:.2f}, of it blocking kevent {kw/1e6:.2f}), "
              f"post {post/1e6:.2f} ms, probe gap {gap/1e6:.2f} ms")
if matched:
    print(f"  slow samples placed: {matched} of {len(slow)} ({T/1e6:.1f} ms); server thread CPU {tot['srv_cpu']/T:.0%}, "
          f"server not running {tot['srv_off']/T:.0%} (wall time in kevent with a timeout {tot['kev_wait']/T:.0%}), "
          f"probe write {tot['pre']/T:.0%}, after the server's callback {tot['post']/T:.0%}; "
          f"probe spin gap > 1 ms in {pg_over}")
if unplaced:
    print(f"  slow samples not placed: {unplaced}")
