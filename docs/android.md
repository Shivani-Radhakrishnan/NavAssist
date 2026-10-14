# NavAssist on Android

## Status

| Part | Status |
|---|---|
| **Navigation logic** (`android/core`) | Done: ported to Kotlin: route graph, A*, guidance, stairs on routes, voice commands, place matching, sign filter, obstacle zones, stair and door hints, door / stairs detector interpretation, relative→metric depth fit, behaviour predictor, trip logs (same CSV as iOS). **79 tests pass**, and they run in CI. |
| **Android app** (`android/app`) | Not started. It needs the Android SDK, and testing it needs an ARCore-capable phone. |

The core is plain Kotlin on the JVM, with no Android dependency. It builds and tests with
nothing but a JDK:

```bash
cd android && ./gradlew :core:test
```

It mirrors `ios/NavAssistCore` one-to-one: same algorithms, same thresholds, same spoken
phrases. The Kotlin tests are ports of the Swift tests, so both platforms are held to the
same behaviour. Not ported yet: saving and loading place files as JSON (`PlaceFile`). That
needs a JSON library and should use the same file format as iOS.

## Plan for the app layer

The app is the thin, platform-specific shell around `core`, the same role
`ios/NavAssist` plays around `NavAssistCore`.

| iOS (today) | Android equivalent | Notes |
|---|---|---|
| ARKit world tracking | **ARCore** `Session` (pose 30–60 Hz) | Same coordinate convention (y up, camera looks −z), so `Vec2.fromWorld(x, z)` works unchanged |
| ARKit world map (save and relocalise offline) | **No offline equivalent.** ARCore **Cloud Anchors** (stored by Google for up to 365 days) | The biggest difference. Re-finding a saved place on Android means uploading visual data to Google's servers. That needs disclosure and consent, or a custom on-device relocaliser |
| LiDAR scene depth | **ARCore Depth API** (`acquireRawDepthImage16Bits` + confidence) | Works from motion on most ARCore phones, and from a ToF sensor where present. Gives metric depth directly, so `MetricZoneAnalyzer` and `StairDetector` get real points without a neural network |
| Depth Anything V2 (Core ML) + `InverseDepthFit` | Only needed on phones without the Depth API: a LiteRT (TFLite) depth model + the same `InverseDepthFit` using ARCore feature points (`PointCloud`) | Same method as the iOS camera-only path |
| ARKit plane classification (doors) | ARCore has no door label indoors; the door / stairs detector below covers it | |
| Vision text recognition (signs) | **ML Kit Text Recognition v2** (on-device) | Feed results through `SignFilter.clean` |
| DoorStairsDetector (Core ML, doors / handles / stairs) | Retrain the same data (`training/detector`) as a LiteRT detector, or ML Kit custom object detection | `DetectionInterpreter` is already ported (`Detections.kt`) |
| `SFSpeechRecognizer` (on-device) | `SpeechRecognizer`, with on-device recognition where available (`createOnDeviceSpeechRecognizer`, Android 13+) | Parse with `VoiceCommand.parse` |
| `AVSpeechSynthesizer` | `TextToSpeech` | Urgent messages use `QUEUE_FLUSH`, others `QUEUE_ADD` |
| UIKit haptics | `VibrationEffect.Composition` | Same patterns: 2 taps = left, 3 = right |
| VoiceOver magic tap | **TalkBack**: one full-screen button with a `contentDescription` | |
| Files app trip export | Share sheet (`Intent.ACTION_SEND`) + app-specific storage | Same CSV, so `analysis/analyze_trips.py` works on Android logs too |

### Suggested module layout

```
android/
  core/   (done)  platform-independent logic + tests
  app/            Jetpack Compose UI, ARCore session, depth -> ObstaclePoint conversion,
                  ML Kit text recognition, SpeechRecognizer, TextToSpeech, haptics,
                  storage, study mode
```

### Requirements for the app module

- Android SDK (platform 35, build-tools 35) and the Android Gradle Plugin. Accepting the
  Android SDK licence is part of installing it.
- An ARCore-supported phone (see Google's *ARCore supported devices* list), ideally with
  Depth API support.
- Minimum Android 8.0 (API 26) for ARCore with Depth. Android 13+ for on-device speech recognition.
