# Predicting hesitation and early turns, and measuring the effect

## What the app does

During every guided trip the app records sensor signals 10 times a second: position, height,
facing direction, speed, distance to the next corner, offset from the route, and the angle to
the next leg (`NavSample`).

Two patterns are detected automatically from that log (`BehaviorDetector`):

- **Hesitation:** stopping for 2 s or more before arriving.
- **Early turn:** drifting 0.6 m or more toward the next leg before reaching the corner.

A predictor (`BehaviorPredictor`) estimates the chance of each pattern in the next ~2 seconds.
It is two logistic regressions over seven features of the last few seconds:

| Feature | Meaning |
|---|---|
| `speed` | walking speed over the last second |
| `speedDrop` | how much slower than the last 5 seconds |
| `headingRate` | how fast the user is turning |
| `oscillation` | looking left and right without settling |
| `nearCorner` | closeness to a real turn |
| `turningTowardNextLeg` | rotating toward the next leg while still well before the corner |
| `lateralTowardTurn` | sideways drift toward the side of the upcoming turn |

When a pattern is likely and predictive cues are on, `AdaptiveCoach` steps in:

- before an early turn: *"Not yet. Keep straight for 2 meters more."*
- when the user hesitates: *"You're on track. Turn right in 3 meters."*

Route directions always take priority over these cues.

The starting weights are hand-tuned. `analysis/train_predictor.py` learns new ones from real
logs. The app loads `predictor.json` from its Documents folder, or from `ios/NavAssist/` at
build time.

## Running a study

1. **Settings › Research study:** turn on **Study mode** and enter a participant ID (P1, P2…).
   Predictive cues then alternate on and off between trips. The starting condition alternates
   between participants (odd IDs start with cues, even IDs without).
2. Map the test area and save the destinations first.
3. Have each participant walk the same set of routes in both conditions, for example 4
   routes × 2 conditions. **A sighted spotter should walk alongside every trip.**
4. **Settings › Export trip logs** creates `all_trips.csv`, one row per sample, with the
   features and events. AirDrop it to a Mac.
5. Compute the effect:
   ```bash
   python analysis/analyze_trips.py all_trips.csv
   ```
   It prints, per participant and overall, navigation errors per trip (off-route events +
   early turns) and hesitations with and without cues. It also prints the % reduction with a
   95% bootstrap confidence interval over participants, and a Wilcoxon signed-rank test if
   `scipy` is installed.
6. Optionally retrain the predictor and check how well it generalises to new people:
   ```bash
   python analysis/train_predictor.py all_trips.csv -o predictor.json
   ```
   It reports leave-one-participant-out precision and recall, and writes the new weights.

### Ethics

Get informed consent from every participant and keep a spotter with them. Trip logs contain
movement data but no names; use participant codes. If the results will be published or used
in academic work, check with your institution's IRB before collecting any data.

## Trip log format

`Trips/<participant>_<time>_<cues|nocues>.json` holds the full `TripLog`. The matching `.csv`
has one row per 10 Hz sample:

`trip, participant, adaptive, destination, outcome, t, x, y, height, heading, target,
dist_to_target, dist_to_destination, dist_to_route, rel_to_target, upcoming_turn,
rel_to_next_leg, lateral_toward_turn, f_speed … f_lateralTowardTurn, event`

`event` lists what happened at that sample, `|`-separated: `hesitation`, `earlyTurn`,
`offRoute`, `cue`, `arrived` or `stopped`.
