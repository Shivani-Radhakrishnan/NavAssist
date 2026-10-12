# BlindNav: indoor navigation for blind and low-vision people

[![Tests](https://github.com/Shivani-Radhakrishnan/blind-nav/actions/workflows/tests.yml/badge.svg)](https://github.com/Shivani-Radhakrishnan/blind-nav/actions/workflows/tests.yml)

BlindNav is an iPhone app that gives turn-by-turn spoken and vibration directions inside
buildings, and warns about obstacles in front of the user.

> **Safety:** BlindNav is an experimental aid. It does not replace a white cane, a guide
> dog, or orientation and mobility training. It can miss obstacles (especially low, thin,
> glass or moving ones), it doesn't detect stairs or drop-offs, and it can lose track.

## How it works

There is one screen. The camera fills it, and **tapping anywhere starts a voice command**.
With VoiceOver on, double-tap the screen or use the two-finger double-tap (magic tap).

- **It maps on its own.** When the app opens, it tries to recognize a place it has mapped
  before (the most recently used place first). If it doesn't recognize one, it starts a new
  map. Every path you walk with the app open is recorded and saved automatically.
- **Voice commands:**
  - "Save this place as kitchen", "Record location kitchen", "This is the front door"
  - "Take me to the kitchen", "Navigate to room 204", "How do I get to the exit"
  - "Where is the exit?" (distance and clock direction), "Where am I?", "What's around?"
  - "Stop", "Repeat", "What places do you know?", "Help"
- **It reads signs.** On-device text recognition reads signs like "Room 204" or "Exit",
  speaks them ("Sign: Room 204"), and remembers where each one was. "Take me to room 204"
  then works even if nobody saved that name. Spoken numbers ("room two oh four") and
  near-misses ("rest room" vs "Restroom") are matched, but different room numbers never are.
- **Directions** follow only paths that have been walked:
  - "Route to Kitchen, 14 meters." / "In 2 meters, turn right." / "Turn right now."
  - Clock-face corrections ("Turn to 9 o'clock"), then "Straight ahead" once facing correctly.
  - "Off route. Recalculating." / "You have arrived at Kitchen."
  - Vibrations: 2 taps = turn left, 3 taps = turn right, a heavy thud = obstacle or stairs.
- **Stairs** are recognized from the heights recorded while walking: "Stairs going down in
  3 meters, about 12 steps. Hold the handrail." / "Stairs now, going down." / "End of stairs."
  Floors are kept apart, so a corridor upstairs is never mistaken for the one below.
- **Obstacle warnings**: "Obstacle ahead, 1 meter, clearer on the left", "Stop. Obstacle
  right in front."
  - **iPhone Pro (LiDAR):** measured 3-D distances, with the floor and ceiling filtered out,
    so head-height obstacles are caught.
  - **Other iPhones:** a Depth Anything V2 network estimates depth from the camera. It needs
    the model file; see [Adding the depth model](#adding-the-depth-model).

Settings (the gear) holds distance units, voice speed, vibrations, and the list of saved maps.

## Status

This is a working prototype that runs on a real iPhone. The navigation logic is covered by
automated tests (below), but the app has **not yet been evaluated with blind users**, and
obstacle detection on non-LiDAR phones is an estimate. Treat it as a research prototype.

## Built with

Swift, SwiftUI, ARKit (visual-inertial tracking, world maps, LiDAR depth), Core ML
(Depth Anything V2), Vision (on-device text recognition), Speech (on-device recognition),
AVSpeechSynthesizer, UIKit haptic feedback, Swift Testing. Prototyped in Python with
OpenCV and NumPy on the TUM RGB-D dataset.

## Repository layout

```
ios/
  BlindNav.xcodeproj      Xcode project for the iPhone app
  BlindNav/               App code: ARKit tracking, speech, haptics, screens
  BlindNavCore/           Navigation logic as a Swift package: route graph, A* routing,
                          turn-by-turn guidance, obstacle zones (tested; runs on a Mac)
prototype/                The original Python step-by-step prototype (TUM RGB-D dataset)
```

## Running the tests (no iPhone needed)

```bash
cd ios/BlindNavCore && swift test
```

There are 40 tests (60 checks including each voice phrasing). They cover routing between separately recorded walks, simplifying ARKit
wobble into clean legs, simulated walks around corners, off-route detection, rate-limited
corrections, obstacle zones (floor removal, head-height obstacles, the "stop" distance),
and making sure warnings don't flicker.

## Building the app onto your iPhone

You need a Mac with **Xcode 16 or later** (free from the Mac App Store) and an iPhone
running iOS 17 or later. The iOS Simulator can show the screens, but it can't track
movement, so real testing needs a real phone.

1. Open `ios/BlindNav.xcodeproj` in Xcode.
2. Select the **BlindNav** target, then **Signing & Capabilities**. Choose your Apple ID
   under *Team* (add it in Xcode › Settings › Accounts; a free account works). Change
   *Bundle Identifier* from `com.shivaniradhakrishnan.BlindNav` to your own if you fork this, such as
   `com.<yourname>.BlindNav`.
3. Connect the iPhone with a cable. On the iPhone, turn on Settings › Privacy & Security ›
   **Developer Mode**.
4. Choose your iPhone at the top of the Xcode window and press **Run** (⌘R).
5. The first time, the iPhone will block the app. Go to Settings › General › VPN & Device
   Management and trust your developer certificate.

With a free Apple account, the app stops opening after 7 days. Press Run again to renew it.

### Adding the depth model

This is only needed for iPhones **without** LiDAR (non-Pro models).

1. Download `DepthAnythingV2SmallF16.mlpackage` from Apple's Core ML models page
   (developer.apple.com/machine-learning/models, under "Depth Anything V2"), or from the
   `apple/coreml-depth-anything-v2-small` repository on Hugging Face.
2. Put it in `ios/BlindNav/` next to `BlindNavApp.swift`. Xcode adds it automatically.
3. Build again. *Obstacle detector* should now say "Using camera depth model".

## Tips for good maps

- Use good, even lighting. ARKit tracks visual detail, so plain white walls and dark rooms
  are hard.
- The first time in a new place, walk slowly and look around. A sighted companion can help
  by walking the main routes once and saving the important places by voice.
- Where two routes cross, walk through the crossing so the app links them.
- Stand exactly where you want to arrive before saying "save this place as...".

## Known limitations

- Routes exist only where someone has walked with the app open.
- Finding the user's location needs the room to look roughly as it did when it was recorded.
  Big lighting or furniture changes can stop the place from being recognized.
- Stairs are only known on paths walked before; new stairs or drop-offs ahead are not detected.
- No moving-obstacle prediction. People walking past are treated like any other obstacle.
- The camera must point forward. Guidance pauses (and says so) if tracking is lost,
  for example when the phone goes into a pocket.

## The Python prototype

`prototype/` is the step-by-step exploration this app grew out of. It covers depth
images (step 2), poses from the TUM RGB-D dataset (step 3), occupancy mapping (steps 4–7),
A* planning with spoken directions (step 8), a simulated walker (step 9), off-route
re-planning (step 10) and live iPhone-camera obstacle warnings with Depth Anything
(step 11). To run it:

```bash
cd prototype && ../venv/bin/python step8.py
```

The datasets (`rgbd_dataset_freiburg1_*`, about 1.2 GB) aren't committed. Download them from
the TUM RGB-D benchmark website.
