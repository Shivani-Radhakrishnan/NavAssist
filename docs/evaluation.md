# Evaluation

What has been measured so far, how, and what hasn't been measured yet.

## Automated tests

```bash
cd ios/NavAssistCore && swift test
```

There are 77 tests. They also run on
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

## Offline benchmarks

`navassist-eval` (in `ios/NavAssistCore/Sources/NavAssistEval`) runs the app's own code on the
TUM RGB-D dataset and on simulated walkers. Results, methods and caveats are in the
[technical report](technical-report.md). In summary:

| Experiment | Result |
|---|---|
| Camera-only depth vs true depth (137 frames) | AbsRel 0.070, δ<1.25 95.3%, median error 6 cm (2–4 cm within 1.5 m) |
| Baseline: one depth conversion for the whole sequence | AbsRel 0.172, δ<1.25 70.0% |
| Points needed for the fit | Nearly flat from 25 points; 10% point noise costs about 0.01 AbsRel |
| Obstacle zones vs true-depth decisions (F1, left / ahead / right) | 0.89 / 0.99 / 0.96, vs 0.53 / 0.57 / 0.61 for the original relative method |
| Distance to the obstacle ahead | Median error 1.5 cm, 90th percentile 17 cm |
| Early-turn predictor, simulated | AUC 0.83; 88% caught about 2 s early at 5.8 false alarms/min, or 13% at ≤ 1/min |

Reproduce with the commands under *Reproducing the results* in the report.
