# Evaluation

What has been measured so far, how, and what hasn't been measured yet.

## Automated tests

```bash
cd ios/NavAssistCore && swift test
```

There are 59 tests (79 checks, counting each voice phrasing separately). They also run on
every push via GitHub Actions.

| Area | What's checked |
|---|---|
| Route graph | Separate walks join at junctions; floors stay apart; unconnected places have no route; old saved files still load |
| Guidance | Simulated walks round corners; ARKit wobble simplified into clean legs; off-route detection; walking past a corner; rate-limited clock-face corrections; "steps" units |
| Stairs on known routes | Flights found from recorded heights; ramps and ARKit drift are *not* stairs; the warning comes before the stairs |
| Voice | 20 phrasings of save, navigate, where-is and the other commands; spoken numbers ("two oh four" → 204); near-miss names; different room numbers never match |
| Signs | Noise filtering (tiny text, URLs, long sentences); the same sign remembered once |
| Obstacles | Floor removal; head-height obstacles; "stop" distance; a basket beside the path is not "ahead"; no flicker around the threshold; "path clear" afterwards |
| Doors and stairs ahead | Door wording; stairs down and steps up found from the walking surface; a wall is not stairs; stairs announced first |
| Relative → metric depth | Scale and offset recovered from noisy points with outliers; bad data rejected |
| Behaviour prediction | Simulated walkers who follow, turn early, or hesitate: detection, prediction *before* the early turn, coaching cues, and silence for a walker who follows perfectly |

The simulated walkers check that each piece works end to end. They are not evidence about
how real people walk.

## Depth accuracy without LiDAR

`analysis/metric_depth_check.swift` measures how well the camera-only pipeline recovers real
distances, using the TUM RGB-D `freiburg1_room` sequence, which has true depth for each frame:

1. Run Depth Anything V2 (the same Core ML model the app uses) on an RGB frame.
2. Take 200 random pixels with known depth (with ±3% noise) as stand-ins for ARKit feature points.
3. Fit `network value = a / meters + b` with the same robust fit the app uses (`InverseDepthFit`).
4. Convert every other pixel to meters and compare with the true depth.

Result over 12 frames spread across the sequence:

| Metric | Value |
|---|---|
| Median absolute error, all pixels | **0.05 m** |
| Median absolute error, objects closer than 2 m | **0.04 m** |
| Pixels within 20% of true depth | **96%** |
| Per-frame median error | 0.02 – 0.13 m |

**Caveats:** real ARKit feature points are noisier than the stand-ins and cluster on textured
surfaces. Dark rooms and blank walls give few points, and then the app falls back to a
stricter relative-depth mode. Accuracy on the phone will be lower than this.

To reproduce:

```bash
xcrun swiftc -O analysis/metric_depth_check.swift -o /tmp/metric_depth_check
/tmp/metric_depth_check path/to/DepthAnythingV2SmallF16.mlmodelc prototype/rgbd_dataset_freiburg1_room
```

The compiled `.mlmodelc` is inside the built app (Xcode's build products), or compile the
package yourself with `xcrun coremlcompiler compile DepthAnythingV2SmallF16.mlpackage .`

## Not yet measured

- Navigation with blind or low-vision users.
- Obstacle and stair detection rates on the phone in real buildings.
- The effect of predictive cues on navigation errors. The tools for that study are in
  [research-study.md](research-study.md).
