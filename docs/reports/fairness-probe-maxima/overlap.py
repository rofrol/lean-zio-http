"""How many of the probe's slow samples overlap a pause of the canary longer
than 1 ms, against how many would by chance (item srx6tz,
docs/reports/fairness-probe-maxima.md). Standard library only.

overlap.py PROBE.txt CANARY.txt THRESHOLD_US

The chance figure places the canary's pauses at random over the probe's
run: a sample of length r overlaps a pause of length g with probability
(r + g) / span, summed over the pauses and the slow samples (capped at 1
per sample). Only pauses within the probe's run count, clipped to it.
"""
import sys

probe = [tuple(map(int, l.split())) for l in open(sys.argv[1])]
canary = [tuple(map(int, l.split())) for l in open(sys.argv[2])]
thr = int(sys.argv[3]) * 1000
t0, t1 = probe[0][0], probe[-1][2]
span = t1 - t0
big = [(max(s, t0), min(s + g, t1)) for s, g in canary if g > 1_000_000 and s + g > t0 and s < t1]
slow = [(s[0], s[2]) for s in probe if s[2] - s[0] > thr]
hit = sum(1 for a, b in slow if any(x < b and y > a for x, y in big))
chance = sum(min(1.0, sum((b - a + y - x) / span for x, y in big)) for a, b in slow)
paused = sum(y - x for x, y in big)
print(f"slow {len(slow)}; overlapping a canary pause > 1 ms: {hit}, by chance {chance:.1f}; "
      f"canary pauses > 1 ms: {len(big)}, {paused/span:.2%} of the run")
