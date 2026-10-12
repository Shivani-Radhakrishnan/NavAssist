# Setting up NavAssist on an iPhone or iPad

## Requirements

- A Mac with **Xcode 16 or later** (free from the Mac App Store).
- An iPhone or iPad with **iOS / iPadOS 17 or later** (any model with an A12 chip or newer). The iOS Simulator can show the screen, but it can't track
  movement, so real use needs a real phone.
- An Apple ID. A free account works.

## Build and install

1. Open `ios/NavAssist.xcodeproj` in Xcode.
2. Add your Apple ID in **Xcode › Settings › Accounts**.
3. Select the **NavAssist** target, then **Signing & Capabilities**:
   - Choose your Apple ID under **Team**.
   - Change **Bundle Identifier** to something unique, such as `com.<yourname>.NavAssist`.
4. Connect the iPhone with a cable, unlock it and tap **Trust**. Turn on
   **Settings › Privacy & Security › Developer Mode**. The phone restarts; tap **Turn On** afterwards.
5. Choose your iPhone at the top of the Xcode window and press **Run** (⌘R).
6. The first launch is blocked until you trust your certificate: **Settings › General ›
   VPN & Device Management ›** your Apple ID **› Trust**.

With a free Apple account, the app stops opening after 7 days. Press Run again to renew it.

## The depth model (iPhones without LiDAR)

Pro iPhones and iPad Pros use their LiDAR sensor and don't need this. On other iPhones, obstacle, door and
stair detection need Apple's Core ML build of Depth Anything V2 (about 50 MB, Apache 2.0
licence). It isn't committed to this repository.

1. Download `DepthAnythingV2SmallF16.mlpackage` from Apple's Core ML models page
   (developer.apple.com/machine-learning/models), or from the
   `apple/coreml-depth-anything-v2-small` repository on Hugging Face. On Hugging Face it is
   three files: `Manifest.json`, `Data/com.apple.CoreML/model.mlmodel` and
   `Data/com.apple.CoreML/weights/weight.bin`.
2. Put the `.mlpackage` folder in `ios/NavAssist/`, next to `NavAssistApp.swift`. Xcode includes
   it automatically.
3. Build again.

Without it, the app still maps, guides and reads signs. It says obstacle warnings are off.

## First use

1. Accept the safety notice.
2. Allow **camera**, **microphone** and **speech recognition** access.
3. Hold the phone upright at chest height, camera facing forward.
4. Tap anywhere and say *"save this place as kitchen"*. Walk somewhere else and do it again.
   Then say *"take me to kitchen"*.

## Tips for good maps

- Use good, even lighting. ARKit tracks visual detail, so plain white walls and dark rooms
  are hard.
- The first time in a new place, walk slowly and look around. A sighted companion can help
  by walking the main routes once and saving the important places by voice.
- Where two routes cross, walk through the crossing so the app links them.
- Stand exactly where you want to arrive before saying "save this place as…".

## Where data is stored

Everything stays on the phone, in the app's Documents folder. It is also visible in the
Files app under **On My iPhone › NavAssist**:

- `Places/<name>/place.json`: the route graph, named places and signs.
- `Places/<name>/world.armap`: the ARKit map used to recognize the place.
- `Trips/`: trip logs (JSON and CSV), if any guided trips were made.

Saved maps can be deleted in Settings.
