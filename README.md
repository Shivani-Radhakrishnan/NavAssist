# NavAssist

**Voice-first indoor navigation for blind and low-vision people, on an iPhone.**

[![Tests](https://github.com/Shivani-Radhakrishnan/NavAssist/actions/workflows/tests.yml/badge.svg)](https://github.com/Shivani-Radhakrishnan/NavAssist/actions/workflows/tests.yml)

NavAssist maps a building as you walk through it. Say *"save this place as kitchen"* to
remember a spot, then later say *"take me to kitchen"* to get turn-by-turn spoken and vibration
directions back. It reads signs, warns about obstacles, doors and stairs, and has one screen:
tap anywhere and speak.

> **Safety:** NavAssist is an experimental research prototype. It does not replace a white
> cane, a guide dog, or orientation and mobility training. It can miss obstacles (especially
> low, thin, glass or moving ones), stair detection is best effort, and it can lose track.

## Features

| | |
|---|---|
| **Automatic mapping** | Recognizes places it has mapped before at launch; otherwise starts a new map. Every path walked with the app open is recorded and saved. |
| **Voice commands** | "Save this place as…", "Take me to…", "Where is the exit?", "Where am I?", "What's around?", "Stop", "Repeat", "Help". Speech recognition runs on the device. |
| **Turn-by-turn guidance** | A* routing over walked paths only. Warns before turns, gives clock-face corrections ("Turn to 9 o'clock"), and re-plans when you go off route. Vibrations: 2 taps = left, 3 = right. |
| **Sign reading** | On-device OCR reads signs ("Room 204", "Exit"), speaks them, and remembers where they are, so "take me to room 204" works without anyone saving it. |
| **Obstacles** | Warns about things in a 60 cm walking corridor, plus anything you're about to brush past. LiDAR on Pro iPhones; on other iPhones, Depth Anything V2 converted to meters with ARKit feature points. |
| **Doors and stairs** | Recognizes doors with ARKit plane classification and Apple's image classifier. Detects drops and steps from the walking-surface profile, and warns about stairs on known routes from recorded heights. |
| **Predictive cues** | Predicts hesitation and early turns from motion signals about 2 s ahead and steps in ("Not yet, keep straight for 2 meters"). Includes a study mode and scripts to measure the effect. |

## How it works

```
 Camera + motion ─▶ ARKit tracking ─▶ position, heading, height ─┬─▶ trail recorder ─▶ route graph (saved)
        │                                                        ├─▶ guidance ─▶ speech + haptics
        │                                                        └─▶ behaviour predictor ─▶ adaptive cues
        ├─▶ depth (LiDAR, or Depth Anything + ARKit points) ─▶ 3-D points ─▶ obstacles, stairs
        ├─▶ ARKit planes + Vision classifier ─▶ doors, stairs
        └─▶ Vision text recognition ─▶ signs ─▶ named destinations
 Tap ─▶ on-device speech recognition ─▶ command parser ─▶ save / navigate / where am I / …
```

The navigation logic (route graph, routing, guidance, stairs, voice command parsing, place
matching, obstacle zones, behaviour prediction, trip logs) is a platform-independent Swift
package, `NavAssistCore`, with 59 tests that run on a Mac without an iPhone.

## Repository layout

```
ios/
  NavAssist.xcodeproj       Xcode project
  NavAssist/                iPhone app: ARKit, camera pipelines, speech, haptics, SwiftUI screen
    AR/                     tracking, obstacle sources (LiDAR / neural depth), sign reader
    Services/               speech, voice commands, haptics, storage, settings
    Views/                  main screen, settings, camera preview
  NavAssistCore/            Swift package: navigation logic and its tests
analysis/                   Python scripts for the user study, plus the depth accuracy check
prototype/                  The original Python prototype on the TUM RGB-D dataset
docs/                       Setup, evaluation and research-study guides
```

## Getting started

Run the tests (any Mac with Swift 5.10 or later):

```bash
cd ios/NavAssistCore && swift test
```

To run the app on an iPhone, see **[docs/setup.md](docs/setup.md)**. You need Xcode 16 or
later, a free Apple ID, and, for obstacle warnings on non-Pro iPhones, Apple's Depth Anything
V2 model.

## Evaluation

- **Automated tests:** 59 tests (79 checks). They cover routing, guidance with simulated walkers,
  stairs, voice parsing, sign matching, obstacle zones, and behaviour prediction.
- **Depth accuracy without LiDAR:** on the TUM RGB-D `freiburg1_room` sequence, converting
  Depth Anything's relative depth to meters with 200 sparse points gave a **5 cm median error**
  and 96% of pixels within 20% of the true depth.

Details and caveats are in **[docs/evaluation.md](docs/evaluation.md)**.

## Research study tools

Every guided trip can be logged at 10 Hz. A study mode alternates predictive cues on and off
between trips, and two scripts compute navigation errors with and without cues and retrain
the predictor. See **[docs/research-study.md](docs/research-study.md)**.

## Status and limitations

NavAssist runs on a real iPhone, but it **has not yet been evaluated with blind users**.
- Routes exist only where someone has walked with the app open.
- Recognizing a place needs it to look roughly as it did when mapped. Big lighting or
  furniture changes can stop it being recognized.
- Without LiDAR, obstacle and stair detection depend on lighting and texture. It can't tell
  whether a door is locked, and it doesn't predict moving obstacles.

## Background

The app grew out of a step-by-step Python prototype built on the TUM RGB-D dataset:
occupancy mapping, A* planning, spoken directions, off-route re-planning and camera
obstacle warnings. See [prototype/README.md](prototype/README.md).

## Built with

Swift, SwiftUI, ARKit, Core ML (Depth Anything V2), Vision, Speech, AVFoundation, and Swift
Testing. The prototype and analysis use Python with OpenCV, NumPy, PyTorch and Transformers.
