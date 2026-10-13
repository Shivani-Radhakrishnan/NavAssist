"""Build a door / door-handle / stairs detection dataset from Open Images V7.

    python training/detector/fetch_openimages.py

Open Images annotations are CC BY 4.0 and the images are CC BY 2.0 (Flickr), downloaded from
the dataset's public bucket; nothing here needs an account. Splits follow Open Images:

    train       up to 2000 images per class from the train split (all door-handle images)
    validation  every validation image with one of the classes (monitoring only)
    test        every test image with one of the classes: the held-out evaluation set

Drawings and paintings (IsDepiction) are left out. Images are resized to at most 512 px on
the long side as they are downloaded, so the whole set is a few hundred MB. Output goes to
~/.cache/navassist/openimages/<split>/ with a Create ML annotations.json per split; boxes
are in pixels, centre-based, as Create ML expects. Seeded and deterministic.
"""
from __future__ import annotations

import csv
import io
import json
import os
import random
import ssl
import sys
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

CLASSES = {"/m/02dgv": "door", "/m/03c7gz": "door handle", "/m/01lynh": "stairs"}
PER_CLASS_TRAIN = 2000
MAX_SIDE = 512
SEED = 0
OUT = Path(os.environ.get("OPENIMAGES_DIR", Path.home() / ".cache" / "navassist" / "openimages"))
ANNOTATIONS = {
    "train": "https://storage.googleapis.com/openimages/v6/oidv6-train-annotations-bbox.csv",
    "validation": "https://storage.googleapis.com/openimages/v5/validation-annotations-bbox.csv",
    "test": "https://storage.googleapis.com/openimages/v5/test-annotations-bbox.csv",
}
IMAGE_URL = "https://open-images-dataset.s3.amazonaws.com/{split}/{image_id}.jpg"


def _ssl_context() -> ssl.SSLContext:
    """Use certifi's CA bundle when available (python.org builds of Python ship without one)."""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


SSL = _ssl_context()


def read_boxes(split: str, local: Path | None) -> dict[str, list[dict]]:
    """Image id -> boxes of the three classes (streams the CSV; the train file is 2.3 GB)."""
    if local and local.exists():
        lines = local.open(encoding="utf-8")
    else:
        lines = io.TextIOWrapper(urllib.request.urlopen(ANNOTATIONS[split], context=SSL), encoding="utf-8")
    boxes: dict[str, list[dict]] = defaultdict(list)
    depiction: set[str] = set()
    for r in csv.DictReader(lines):
        label = CLASSES.get(r["LabelName"])
        if label is None:
            continue
        if r["IsDepiction"] == "1":
            depiction.add(r["ImageID"])
        boxes[r["ImageID"]].append({"label": label, "box": [float(r["XMin"]), float(r["YMin"]),
                                                            float(r["XMax"]), float(r["YMax"])]})
    return {i: b for i, b in boxes.items() if i not in depiction}


def choose_train(boxes: dict[str, list[dict]]) -> list[str]:
    rng = random.Random(SEED)
    by_class: dict[str, list[str]] = defaultdict(list)
    for image_id in sorted(boxes):
        for label in {b["label"] for b in boxes[image_id]}:
            by_class[label].append(image_id)
    chosen: set[str] = set()
    for label in sorted(by_class):
        ids = by_class[label]
        rng.shuffle(ids)
        chosen.update(ids if label == "door handle" else ids[:PER_CLASS_TRAIN])
    return sorted(chosen)


def fetch(split: str, image_id: str, boxes: list[dict]) -> dict | None:
    from PIL import Image

    dest = OUT / split / f"{image_id}.jpg"
    try:
        if not dest.exists():
            data = urllib.request.urlopen(IMAGE_URL.format(split=split, image_id=image_id), timeout=30,
                                          context=SSL).read()
            img = Image.open(io.BytesIO(data)).convert("RGB")
            img.thumbnail((MAX_SIDE, MAX_SIDE))
            dest.parent.mkdir(parents=True, exist_ok=True)
            img.save(dest, quality=88)
        w, h = Image.open(dest).size
    except Exception as exc:   # a few Flickr images have gone missing
        print(f"  skip {split}/{image_id}: {exc}", file=sys.stderr)
        return None
    anns = [{"label": b["label"], "coordinates": {
        "x": round((b["box"][0] + b["box"][2]) / 2 * w, 1), "y": round((b["box"][1] + b["box"][3]) / 2 * h, 1),
        "width": round((b["box"][2] - b["box"][0]) * w, 1), "height": round((b["box"][3] - b["box"][1]) * h, 1)}}
        for b in boxes]
    return {"image": dest.name, "annotations": anns}


def main() -> int:
    local = {s: Path(p) for s, p in (a.split("=", 1) for a in sys.argv[1:])}   # e.g. train=filtered.csv
    for split in ("train", "validation", "test"):
        boxes = read_boxes(split, local.get(split))
        ids = choose_train(boxes) if split == "train" else sorted(boxes)
        with ThreadPoolExecutor(16) as pool:
            items = [r for r in pool.map(lambda i: fetch(split, i, boxes[i]), ids) if r]
        (OUT / split).mkdir(parents=True, exist_ok=True)
        (OUT / split / "annotations.json").write_text(json.dumps(items), encoding="utf-8")
        counts = defaultdict(int)
        for it in items:
            for a in it["annotations"]:
                counts[a["label"]] += 1
        print(f"{split}: {len(items)} images, boxes {dict(counts)}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
