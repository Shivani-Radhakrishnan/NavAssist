# Door, door-handle and stairs detector

`ios/NavAssist/Models/DoorStairsDetector.mlmodel` (6.9 MB) finds doors, door handles and
stairs in the camera picture. With depth, NavAssist turns the boxes into *"Door ahead, 2
meters. Handle on the right."* and *"Stairs ahead, 3 meters. Slow down."*
(`NavAssistCore/Detections.swift`, mirrored in Kotlin). Before it, NavAssist used Apple's
built-in image classifier, which only says whether a door or stairs are probably somewhere in
the picture.

## Data

[Open Images V7](https://storage.googleapis.com/openimages/web/index.html) (annotations CC BY
4.0, images CC BY 2.0), classes *Door*, *Door handle* and *Stairs*; drawings and paintings
excluded. `fetch_openimages.py` streams the annotation files, downloads the images from the
dataset's public bucket and resizes them to 512 px (261 MB in `~/.cache/navassist/openimages`;
not committed).

| Split | Images | Door boxes | Door-handle boxes | Stairs boxes | Used for |
|---|---|---|---|---|---|
| Open Images train (sampled, seed 0) | 4,494 | 3,227 | 724 | 2,612 | training |
| Open Images validation | 255 | 282 | 36 | 45 | choosing settings |
| Open Images test | 717 | 782 | 129 | 153 | the numbers below, scored once |

## Model

Create ML object detector (`train.swift`): transfer learning on Apple's object feature print,
13 × 13 grid, batch 32. Create ML was chosen over a PyTorch detector because it trains on the
Mac's GPU, writes a Core ML model with non-maximum suppression in the format Vision reads
directly, and leaves no licence conflict with NavAssist's MIT licence (the trained model is
ours; Ultralytics' AGPL would not be).

| Run | Iterations | Training time | Validation mAP@0.5 |
|---|---|---|---|
| shipped | 1,000 | 16 min (M1) | 0.357 |
| longer | 2,000 | 3 h 10 min (CPU shared with another job) | 0.374 |

The shipped model is the 1,000-iteration run; the longer run was only 0.017 better on
validation and was not saved.

## Results on the held-out test split

**Does it beat what the app used before?** Image level: does the picture contain a door / stairs?
(`compare_classifier.swift`, 717 test images; Apple's classifier at the thresholds the app used.)

| | Apple's image classifier (before) | DoorStairsDetector |
|---|---|---|
| Stairs in view: precision / recall | 0.86 / 0.47 | **0.91 / 0.79** |
| Door in view: precision / recall | 0.98 / 0.38 | 0.95 / **0.71** |

The detector finds almost twice as many doors at nearly the same precision, is better on both
counts for stairs, and is the only one of the two that says *where* they are.

**Boxes** (Create ML's evaluation, IoU ≥ 0.5): mAP 0.313 (door 0.268, door handle 0.368,
stairs 0.303); mAP@0.5:0.95 0.114.

**At the app's own thresholds** (fixed before training: door 0.5, door handle 0.35, stairs
0.5; a box counts when it overlaps a labelled box with IoU ≥ 0.5; `benchmark.swift`):

| | Precision | Recall |
|---|---|---|
| Stairs | 0.62 | 0.54 |
| Door handle | 0.48 | 0.36 |
| Door | 0.48 | 0.31 |

Box-level numbers are much lower than image-level ones mostly because a box must line up
closely with a labelled one; for a spoken hint, "there is a door roughly here" is what matters,
and the distance comes from depth at the box, not from the box edges.

**Speed** (Vision on an M1 Mac, 712 test images): median 8.9 ms per image with the GPU /
Neural Engine, 24.7 ms on the CPU alone. The app runs it about once a second. On-iPhone
timing has not been measured yet.

## Limitations

- Open Images photos are mostly outdoor and street scenes taken by sighted photographers; indoor
  corridors filmed from chest height are under-represented, so real use will differ.
- The test images were chosen because they contain at least one of the three classes, so the
  base rates are not those of walking through a building.
- Door handles are small and rare in the data (724 training boxes) and the weakest class.
- Labels are Open Images' own; doors visible but not annotated count as false positives.

## Reproduce

```bash
python training/detector/fetch_openimages.py                       # ~260 MB of images
swift training/detector/train.swift objectprint 1000 --test        # trains, scores test, writes the model
swift training/detector/benchmark.swift training/detector/output/DoorStairsDetector.mlmodel
swift training/detector/compare_classifier.swift training/detector/output/DoorStairsDetector.mlmodel
```

Results are in `results/`.
