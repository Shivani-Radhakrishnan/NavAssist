rootProject.name = "NavAssist"

// Platform-independent navigation logic (a port of ios/NavAssistCore). Builds and tests on any
// JVM, no Android SDK needed. The Android app module (ARCore camera, speech, haptics) will
// depend on it; see docs/android.md.
include(":core")
