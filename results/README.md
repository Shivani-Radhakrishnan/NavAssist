# Results

Raw outputs of `navassist-eval`. They are the source of every number and figure in
[docs/technical-report.md](../docs/technical-report.md). Seeds are fixed, so re-running gives
the same files.

## `tum_fr1_room/`: camera-only depth and obstacle zones on TUM RGB-D `freiburg1_room` (137 frames)

| File | Contents |
|---|---|
| `depth_per_frame.csv` | Per frame and method (`per_frame_fit`, `global_fit`): points used, fit R², AbsRel, RMSE, δ<1.25, median absolute error |
| `depth_error_by_distance.csv` | Median absolute error and AbsRel in 0.5 m true-distance bins |
| `ablation_points_noise.csv` | AbsRel and δ<1.25 for 10–400 sparse points × 0 / 3 / 10% noise |
| `obstacle_zones.csv` | Left / ahead / right blocked flags from true depth (ground truth), NavAssist's metric depth, and the original relative method, plus the distance ahead |
| `qualitative_frames.csv`, `estimated_depth_*.png` | Frames used in Figure 1. Estimated depth is a 16-bit PNG in millimeters |

## `simulation/`: behaviour predictor on 600 simulated trips (300 train / 300 test)

| File | Contents |
|---|---|
| `predictor_events.csv` | Event-level recall, median lead time, false alarms per minute and sample-level AUC, per model / smoothing / threshold |
| `predictor_roc.csv` | ROC curve points |
| `predictor_trained_on_simulation.json` | Weights trained on the simulated trips (the app's `predictor.json` format) |

Simulation results describe the predictor under assumed walking behaviour, not real users.
