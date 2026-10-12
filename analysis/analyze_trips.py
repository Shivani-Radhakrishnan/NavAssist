"""Compare navigation errors with and without BlindNav's predictive cues.

Usage:
    python analysis/analyze_trips.py all_trips.csv [more.csv ...]
    python analysis/analyze_trips.py path/to/Trips/        (every .csv in the folder)

Export the CSV from the app: Settings > Research study > Export trip logs.

Navigation errors per trip = off-route events + early turns, both detected automatically
from the sensor log. Each participant's trips are averaged per condition first, so someone
who walked more trips doesn't count more, and the comparison is within-participant.
"""
import csv
import random
import sys
from collections import defaultdict
from pathlib import Path


def load_rows(paths):
    files = []
    for p in map(Path, paths):
        files += sorted(p.glob("*.csv")) if p.is_dir() else [p]
    seen = set()
    for f in files:
        if f.name == "all_trips.csv" and len(files) > 1:
            continue                        # the combined file duplicates the per-trip files
        with open(f, newline="") as fh:
            for row in csv.DictReader(fh):
                key = (row["trip"], row["t"])
                if key not in seen:
                    seen.add(key)
                    yield row


def summarize_trips(rows):
    trips = {}
    for r in rows:
        t = trips.setdefault(r["trip"], {
            "participant": r["participant"], "adaptive": r["adaptive"] == "1",
            "destination": r.get("destination", ""), "outcome": r.get("outcome", ""),
            "duration": 0.0, "offRoute": 0, "earlyTurn": 0, "hesitation": 0, "cue": 0,
        })
        t["duration"] = max(t["duration"], float(r["t"]))
        for ev in filter(None, r["event"].split("|")):
            if ev in t:
                t[ev] += 1
    for t in trips.values():
        t["errors"] = t["offRoute"] + t["earlyTurn"]
    return trips


def mean(xs):
    return sum(xs) / len(xs) if xs else float("nan")


def main(paths):
    trips = summarize_trips(load_rows(paths))
    if not trips:
        sys.exit("No trips found.")

    by_person = defaultdict(lambda: {True: [], False: []})
    for t in trips.values():
        by_person[t["participant"]][t["adaptive"]].append(t)

    print(f"{'participant':<12}{'trips (cues/no cues)':>22}{'errors/trip no cues':>22}{'errors/trip cues':>18}"
          f"{'hesitations/trip no cues':>26}{'hesitations/trip cues':>23}")
    paired = []
    for p in sorted(by_person):
        cues, base = by_person[p][True], by_person[p][False]
        e_base, e_cues = mean([t["errors"] for t in base]), mean([t["errors"] for t in cues])
        h_base, h_cues = mean([t["hesitation"] for t in base]), mean([t["hesitation"] for t in cues])
        print(f"{p:<12}{f'{len(cues)}/{len(base)}':>22}{e_base:>22.2f}{e_cues:>18.2f}{h_base:>26.2f}{h_cues:>23.2f}")
        if cues and base:
            paired.append((e_base, e_cues, h_base, h_cues))

    n = len(paired)
    print()
    if n == 0:
        sys.exit("No participant has trips in both conditions yet; turn on Study mode in the app.")
    base = mean([x[0] for x in paired])
    cues = mean([x[1] for x in paired])
    reduction = (base - cues) / base * 100 if base > 0 else float("nan")

    # Bootstrap over participants for a 95% confidence interval on the reduction.
    rng = random.Random(0)
    boots = []
    for _ in range(10000):
        s = [paired[rng.randrange(n)] for _ in range(n)]
        b, c = mean([x[0] for x in s]), mean([x[1] for x in s])
        if b > 0:
            boots.append((b - c) / b * 100)
    boots.sort()
    lo, hi = (boots[int(0.025 * len(boots))], boots[int(0.975 * len(boots))]) if boots else (float("nan"),) * 2

    print(f"Participants with both conditions: {n}   Trips: {len(trips)}")
    print(f"Navigation errors per trip: {base:.2f} without cues, {cues:.2f} with cues")
    print(f"Reduction: {reduction:.0f}%  (95% bootstrap CI {lo:.0f}% to {hi:.0f}%)")
    try:
        from scipy.stats import wilcoxon
        diffs = [x[0] - x[1] for x in paired]
        if any(diffs):
            print(f"Wilcoxon signed-rank test: p = {wilcoxon([x[0] for x in paired], [x[1] for x in paired]).pvalue:.3f}")
    except ImportError:
        print("(Install scipy for a Wilcoxon signed-rank test.)")
    if n < 8:
        print(f"\nNote: only {n} participants. Treat this as a pilot result.")
    arrived = mean([t["outcome"] == "arrived" for t in trips.values()]) * 100
    print(f"Trips that reached the destination: {arrived:.0f}%")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
