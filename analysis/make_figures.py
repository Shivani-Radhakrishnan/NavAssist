"""Make the figures in docs/images/ from the CSVs in results/.

    python analysis/make_figures.py

Needs matplotlib and numpy (prototype/requirements.txt) and the TUM fr1_room sequence in
prototype/ for the qualitative depth figure.
"""
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "results"
OUT = ROOT / "docs" / "images"
OUT.mkdir(parents=True, exist_ok=True)
plt.rcParams.update({"font.size": 11, "axes.spines.top": False, "axes.spines.right": False,
                     "figure.dpi": 150, "savefig.bbox": "tight"})
BLUE, ORANGE, GRAY, GREEN = "#2563eb", "#ea580c", "#9ca3af", "#16a34a"


def rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def num(x):
    return float(x) if x not in ("", None) else float("nan")


# 1. Depth error vs true distance --------------------------------------------------------
def depth_by_distance():
    r = rows(RES / "tum_fr1_room" / "depth_error_by_distance.csv")
    fig, ax = plt.subplots(figsize=(6.5, 3.8))
    for method, color, label in [("per_frame_fit", BLUE, "Per-frame fit (NavAssist)"),
                                 ("global_fit", ORANGE, "Single fit for the sequence")]:
        pts = [(num(x["true_depth_bin_m"]), num(x["median_abs_m"]) * 100) for x in r
               if x["method"] == method and int(x["pixels"]) > 1000]
        ax.plot(*zip(*pts), "o-", color=color, label=label, lw=2)
    ax.set_xlabel("True distance (m)")
    ax.set_ylabel("Median absolute error (cm)")
    ax.set_title("Camera-only depth error by distance (TUM fr1_room)")
    ax.axvspan(0, 1.5, color=GREEN, alpha=0.07)
    ax.text(0.75, ax.get_ylim()[1] * 0.92, "obstacle\nwarning range", ha="center", va="top", fontsize=9, color=GREEN)
    ax.legend(frameon=False)
    fig.savefig(OUT / "depth_error_by_distance.png")
    plt.close(fig)


# 2. Ablation: number of feature points and their noise ------------------------------------
def ablation():
    r = rows(RES / "tum_fr1_room" / "ablation_points_noise.csv")
    fig, ax = plt.subplots(figsize=(6.5, 3.8))
    for noise, color in [("0.00000", GREEN), ("0.03000", BLUE), ("0.10000", ORANGE)]:
        xs, ys = [], []
        for n in [10, 25, 50, 100, 200, 400]:
            v = [num(x["abs_rel"]) for x in r if x["points"] == str(n) and x["noise"] == noise and x["fit_ok"] == "1"]
            xs.append(n)
            ys.append(np.median(v))
        ax.plot(xs, ys, "o-", color=color, lw=2, label=f"{float(noise) * 100:.0f}% noise on points")
    ax.set_xscale("log")
    ax.set_xticks([10, 25, 50, 100, 200, 400], ["10", "25", "50", "100", "200", "400"])
    ax.set_ylim(0, 0.08)
    ax.set_xlabel("Tracked points used for the fit")
    ax.set_ylabel("Median AbsRel (lower is better)")
    ax.set_title("How many ARKit points are needed?")
    ax.legend(frameon=False)
    fig.savefig(OUT / "ablation_points_noise.png")
    plt.close(fig)


# 3. Obstacle zones vs ground truth: NavAssist (metric) vs the original relative method -----
def obstacles():
    r = rows(RES / "tum_fr1_room" / "obstacle_zones.csv")
    zones = ["left", "center", "right"]
    stats = {}
    for m in ["metric", "relative"]:
        for z in zones:
            tp = sum(1 for x in r if x[f"gt_{z}"] == "1" and x[f"{m}_{z}"] == "1")
            fp = sum(1 for x in r if x[f"gt_{z}"] == "0" and x[f"{m}_{z}"] == "1")
            fn = sum(1 for x in r if x[f"gt_{z}"] == "1" and x[f"{m}_{z}"] == "0")
            p = tp / (tp + fp) if tp + fp else float("nan")
            rc = tp / (tp + fn) if tp + fn else float("nan")
            stats[m, z] = (p, rc, 2 * p * rc / (p + rc) if p + rc else 0, fp)
    fig, axes = plt.subplots(1, 3, figsize=(10, 3.4), sharey=True)
    for ax, (k, name) in zip(axes, [(0, "Precision"), (1, "Recall"), (2, "F1")]):
        x = np.arange(3)
        ax.bar(x - 0.2, [stats["metric", z][k] for z in zones], 0.4, color=BLUE, label="NavAssist (meters)")
        ax.bar(x + 0.2, [stats["relative", z][k] for z in zones], 0.4, color=GRAY, label="Relative depth (original)")
        ax.set_xticks(x, ["Left", "Ahead", "Right"])
        ax.set_title(name)
        ax.set_ylim(0, 1.05)
    axes[0].legend(frameon=False, loc="lower left", fontsize=9)
    fig.suptitle("Obstacle zones vs ground truth from true depth (TUM fr1_room, 137 frames)", y=1.03)
    fig.savefig(OUT / "obstacle_zones.png")
    plt.close(fig)
    return stats


# 4. Predictor ROC (simulated walkers) ------------------------------------------------------
def roc():
    r = rows(RES / "simulation" / "predictor_roc.csv")
    ev = {x["model"] + "|" + x["event"] for x in r}
    summary = rows(RES / "simulation" / "predictor_events.csv")
    auc = {(x["model"] + ("+smoothing" if num(x["smoothing"]) > 0 else ""), x["event"]): num(x["sample_auc"]) for x in summary}
    fig, axes = plt.subplots(1, 2, figsize=(9, 4))
    for ax, event, title in [(axes[0], "earlyTurn", "Early turn"), (axes[1], "hesitation", "Hesitation")]:
        for model, color, label in [("hand-tuned", GRAY, "Hand-tuned weights"), ("trained", BLUE, "Trained on simulated logs")]:
            if f"{model}|{event}" not in ev:
                continue
            pts = [(num(x["fpr"]), num(x["tpr"])) for x in r if x["model"] == model and x["event"] == event]
            ax.plot(*zip(*([(0, 0)] + pts)), color=color, lw=2, label=f"{label} (AUC {auc.get((model, event), float('nan')):.2f})")
        ax.plot([0, 1], [0, 1], ":", color="#d1d5db")
        ax.set_title(f"{title}: event in the next 2 s")
        ax.set_xlabel("False positive rate")
        ax.legend(frameon=False, fontsize=9, loc="lower right")
    axes[0].set_ylabel("True positive rate")
    fig.suptitle("Behaviour predictor on SIMULATED walkers (300 test trips)", y=1.02)
    fig.savefig(OUT / "predictor_roc_simulated.png")
    plt.close(fig)


# 5. Qualitative depth: RGB / true / estimated / error -------------------------------------
def qualitative():
    from PIL import Image  # bundled with matplotlib's dependencies
    q = rows(RES / "tum_fr1_room" / "qualitative_frames.csv")[:3]
    seq = ROOT / "prototype" / "rgbd_dataset_freiburg1_room"
    if not seq.exists():
        print("TUM sequence not found; skipping qualitative figure")
        return
    fig, axes = plt.subplots(len(q), 4, figsize=(12, 2.6 * len(q)))
    for row, x in zip(axes, q):
        rgb = np.asarray(Image.open(seq / x["rgb"]))
        true = np.asarray(Image.open(seq / x["true_depth"])).astype(float) / 5000
        est = np.asarray(Image.open(RES / "tum_fr1_room" / x["estimated_depth_png"])).astype(float) / 1000
        true[true == 0] = np.nan
        est[est == 0] = np.nan
        err = np.abs(est - true)
        vmax = np.nanpercentile(true, 98)
        row[0].imshow(rgb)
        row[1].imshow(true, cmap="magma_r", vmin=0, vmax=vmax)
        im = row[2].imshow(est, cmap="magma_r", vmin=0, vmax=vmax)
        e = row[3].imshow(err * 100, cmap="viridis", vmin=0, vmax=30)
        for a in row:
            a.axis("off")
        row[0].text(-0.04, 0.5, f"frame {x['frame']}", transform=row[0].transAxes, rotation=90,
                    ha="right", va="center", fontsize=10, color="#4b5563")
    for a, t in zip(axes[0], ["Camera image", "True depth, m (Kinect)", "NavAssist estimate, m", "Error, cm"]):
        a.set_title(t)
    fig.colorbar(im, ax=axes[:, 1:3], fraction=0.02, pad=0.01)
    fig.colorbar(e, ax=axes[:, 3], fraction=0.05, pad=0.02)
    fig.savefig(OUT / "depth_qualitative.png")
    plt.close(fig)


if __name__ == "__main__":
    depth_by_distance()
    ablation()
    s = obstacles()
    roc()
    qualitative()
    for (m, z), v in sorted(s.items()):
        print(f"{m:9s} {z:7s} precision {v[0]:.2f} recall {v[1]:.2f} F1 {v[2]:.2f} false alarms {v[3]}")
    print("figures in", OUT)
