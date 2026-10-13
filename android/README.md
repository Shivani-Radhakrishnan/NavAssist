# NavAssist for Android

`core/` is NavAssist's navigation logic in Kotlin: a one-to-one port of `ios/NavAssistCore`
with its tests. It runs on any JVM, so no Android SDK is needed:

```bash
./gradlew :core:test        # 79 tests
```

The Android app itself (ARCore, speech, haptics) isn't built yet. The plan, and how each
iPhone feature maps to Android, is in [docs/android.md](../docs/android.md).
