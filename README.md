# BlindNav: indoor navigation for blind and low-vision people

BlindNav is an iPhone app that gives turn-by-turn spoken and vibration directions inside
buildings, and warns about obstacles in front of the user.

> **Safety:** BlindNav is an experimental aid. It does not replace a white cane, a guide
> dog, or orientation and mobility training. It can miss obstacles (especially low, thin,
> glass or moving ones), it doesn't detect stairs or drop-offs, and it can lose track.

## How it works

1. **A sighted helper records the place once.** They open *Record a place* and walk every
   route the user will need at a normal pace, holding the phone upright. At each
   destination they tap **Add landmark** and name it ("Kitchen", "Front door", "Desk 14").
   The app saves the walked paths and an ARKit map of the surroundings.
2. **The user navigates.** They open *Navigate*, choose the place, and slowly turn around
   until the phone recognizes where they are. Then they pick a destination from a list
   that works with VoiceOver.
3. **Guidance.** The app plans the shortest route along the recorded paths, then gives
   directions as the user walks:
   - "Route to Kitchen, 14 meters." / "Walk straight ahead, 6 meters."
   - "In 2 meters, turn right." then "Turn right now. Then walk 4 meters."
   - Clock-face corrections when the user faces the wrong way: "Turn to 9 o'clock". Once
     they're facing correctly: "Straight ahead".
   - "Off route. Recalculating." when they drift more than 1.5 m from the route.
   - "You have arrived at Kitchen."
   - Vibrations: 2 taps = turn left, 3 taps = turn right, a heavy thud = obstacle.
4. **Obstacle warnings** run during navigation, and also on their own (*Obstacle detector*):
   "Obstacle ahead, 1 meter, clearer on the left", "Stop. Obstacle right in front."
   - **iPhone Pro (LiDAR):** measured 3-D distances. The floor and ceiling are filtered
     out by height, so head-height obstacles that a cane misses are still caught.
   - **Other iPhones:** a Depth Anything V2 neural network estimates depth from the camera,
     using the floor as a ruler, the same method as `prototype/step11.py`. Less reliable.
     It needs the model file; see [Adding the depth model](#adding-the-depth-model).

Only recorded paths are used for routes, so the app never sends someone through space
that nobody has actually walked.

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

There are 28 tests. They cover routing between separately recorded walks, simplifying ARKit
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

## Tips for recording a good place

- Use good, even lighting. ARKit tracks visual detail, so plain white walls and dark rooms
  are hard.
- Walk slowly and sweep the camera across walls and furniture. Save when the screen shows
  **Map quality: good**.
- Walk the routes the user will actually take, through the middle of corridors and
  doorways. Where two routes cross, walk through the crossing so the app links them.
- Stand exactly where the user should arrive before you add a landmark.
- Use *Pause* while walking somewhere that shouldn't become a route.
- Record again (*Record a place › Add routes to a saved place*) if furniture moves a lot.

## Known limitations

- Routes exist only where someone has walked. Destinations must be added by a sighted helper.
- Finding the user's location needs the room to look roughly as it did when it was recorded.
  Big lighting or furniture changes can stop the place from being recognized.
- No stair or drop-off detection.
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
