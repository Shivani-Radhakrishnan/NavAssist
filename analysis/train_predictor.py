"""Train NavAssist's hesitation and early-turn predictor from real trip logs.

Usage:
    python analysis/train_predictor.py all_trips.csv [-o predictor.json]

Each 10 Hz sample is labelled positive if a hesitation (or early turn) starts within the
next 2 seconds, so the model learns to warn *before* it happens. Two logistic regressions
are fitted on the f_* feature columns the app exports (same order the app uses), evaluated
with leave-one-participant-out, and saved as predictor.json.

To use the trained model: copy predictor.json into the NavAssist folder in the Files app
(On My iPhone > NavAssist), or into ios/NavAssist/ before building.
"""
import argparse
import csv
import json
import math
from collections import defaultdict

LOOKAHEAD = 2.0
THRESHOLD = 0.6


def load(paths):
    trips = defaultdict(list)
    for path in paths:
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                trips[r["trip"]].append(r)
    return trips


def build(trips):
    """Rows of (participant, features, hesitation_soon, early_turn_soon)."""
    feature_cols = None
    out = []
    for rows in trips.values():
        feature_cols = feature_cols or [c for c in rows[0] if c.startswith("f_")]
        events = defaultdict(list)
        for r in rows:
            for ev in filter(None, r["event"].split("|")):
                events[ev].append(float(r["t"]))
        for r in rows:
            if not r[feature_cols[0]]:
                continue                      # first 1.5 s of a trip has no features yet
            t = float(r["t"])
            soon = lambda kind: any(t < e <= t + LOOKAHEAD for e in events[kind])
            out.append((r["participant"], [float(r[c]) for c in feature_cols], soon("hesitation"), soon("earlyTurn")))
    return feature_cols, out


def sigmoid(z):
    return 1 / (1 + math.exp(-max(-30, min(30, z))))


def train(xs, ys, epochs=600, lr=0.5, l2=1e-3):
    """Same algorithm as LogisticModel.train in the app: class-weighted batch gradient descent."""
    d = len(xs[0])
    w, b = [0.0] * d, 0.0
    pos = sum(ys)
    if pos == 0 or pos == len(ys):
        return None
    wp, wn = len(ys) / (2 * pos), len(ys) / (2 * (len(ys) - pos))
    for _ in range(epochs):
        gw, gb = [0.0] * d, 0.0
        for x, y in zip(xs, ys):
            err = (sigmoid(sum(wi * xi for wi, xi in zip(w, x)) + b) - y) * (wp if y else wn)
            for j in range(d):
                gw[j] += err * x[j]
            gb += err
        n = len(xs)
        w = [wj - lr * (gw[j] / n + l2 * wj) for j, wj in enumerate(w)]
        b -= lr * gb / n
    return w, b


def evaluate(model, xs, ys):
    w, b = model
    pred = [sigmoid(sum(wi * xi for wi, xi in zip(w, x)) + b) >= THRESHOLD for x in xs]
    tp = sum(p and y for p, y in zip(pred, ys))
    fp = sum(p and not y for p, y in zip(pred, ys))
    fn = sum(y and not p for p, y in zip(pred, ys))
    precision = tp / (tp + fp) if tp + fp else float("nan")
    recall = tp / (tp + fn) if tp + fn else float("nan")
    return precision, recall


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="+")
    ap.add_argument("-o", "--output", default="predictor.json")
    args = ap.parse_args()

    cols, data = build(load(args.csv))
    print(f"{len(data)} samples, features: {', '.join(c[2:] for c in cols)}")
    people = sorted({d[0] for d in data})
    result = {}
    for name, idx in (("hesitation", 2), ("earlyTurn", 3)):
        xs = [d[1] for d in data]
        ys = [d[idx] for d in data]
        print(f"\n{name}: {sum(ys)} positive samples of {len(ys)}")
        if len(people) >= 2:
            scores = []
            for held_out in people:
                tr = [(d[1], d[idx]) for d in data if d[0] != held_out]
                te = [(d[1], d[idx]) for d in data if d[0] == held_out]
                m = train([x for x, _ in tr], [y for _, y in tr])
                if m and any(y for _, y in te):
                    scores.append(evaluate(m, [x for x, _ in te], [y for _, y in te]))
            if scores:
                p = sum(s[0] for s in scores if s[0] == s[0]) / max(1, sum(1 for s in scores if s[0] == s[0]))
                r = sum(s[1] for s in scores) / len(scores)
                print(f"  leave-one-participant-out at p >= {THRESHOLD}: precision {p:.2f}, recall {r:.2f}")
        model = train(xs, ys)
        if model is None:
            print("  not enough positive examples yet; keeping the app's default weights")
            continue
        result[name] = {"weights": [round(v, 4) for v in model[0]], "bias": round(model[1], 4)}
        print("  weights: " + ", ".join(f"{c[2:]}={v:+.2f}" for c, v in zip(cols, model[0])) + f", bias={model[1]:+.2f}")

    if len(result) < 2:
        print("\nNeed examples of both hesitation and early turns to write predictor.json.")
        return
    with open(args.output, "w") as fh:
        json.dump(result, fh, indent=2)
    print(f"\nWrote {args.output}")


if __name__ == "__main__":
    main()
