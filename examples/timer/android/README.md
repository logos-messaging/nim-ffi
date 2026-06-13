# Android example — Kotlin over the native C ABI (JNI)

An Android library module that wraps the timer library's **native**
(zero-serialization) C ABI behind an idiomatic Kotlin class, `TimerNode`, via a
small JNI shim. Struct returns come back as typed Kotlin values.

```kotlin
TimerNode("my-app").use { node ->
    println(node.version())              // "nim-timer v0.1.0"
    val r = node.echo("hello", delayMs = 5)
    println("${r.echoed} / ${r.timerName}")
}
```

## How it fits together

```
 Kotlin TimerNode  ──external fun──▶  libmy_timer_jni.so  ──C ABI──▶  libmy_timer.so
 (src/main/kotlin)                    (jni/my_timer_jni.c)            (Nim, generated)
```

- `libmy_timer.so` — the Nim library, exporting the native C ABI.
- `libmy_timer_jni.so` — a JNI shim that turns each `native` Kotlin method into a
  blocking call into that ABI, reading the typed `EchoResponse` struct out of the
  result callback. It `NEEDS` `libmy_timer.so` at load time.

| Path | Description |
|------|-------------|
| `build-libs.sh` | Cross-compiles both `.so`s per ABI into `src/main/jniLibs/<abi>/`. |
| `jni/my_timer_jni.c` | The JNI bridge. |
| `src/main/kotlin/.../TimerNode.kt` | The Kotlin wrapper + `EchoResult`. |
| `build.gradle.kts`, `settings.gradle.kts` | Library module build files. |
| `src/androidTest/...` | Instrumented test (runs on a device/emulator). |

## Build

```sh
cd examples/timer/android
export ANDROID_NDK_ROOT=/path/to/android-ndk   # or rely on the default
./build-libs.sh                                  # arm64-v8a + x86_64 by default
```

This stages `libmy_timer.so` + `libmy_timer_jni.so` under `src/main/jniLibs/`.
The Android Gradle plugin packages everything under `jniLibs/` into the AAR/APK
automatically — no extra Gradle config needed.

Add ABIs by extending the table at the bottom of `build-libs.sh` and the
`abiFilters` in `build.gradle.kts`.

## Use it

- **As a module**: drop `android/` into your project, `include(":mytimer")` in
  your `settings.gradle`, and `implementation(project(":mytimer"))`.
- **By hand**: copy `src/main/jniLibs/<abi>/*.so` into your app's `jniLibs/` and
  `TimerNode.kt` into your sources.

Then `org.logos.mytimer.TimerNode` is ready to use.

## Run the test

```sh
./gradlew connectedAndroidTest        # needs a connected device or emulator
```

## Notes

- This is the **native, same-process** path — the app loads the library directly.
  The CBOR ABI is for inter-process communication only (see [`../ipc`](../ipc)).
- Each call blocks on a condvar in the JNI shim until the library's FFI-thread
  callback fires, so the Kotlin API is simple and synchronous.
- Regenerate `../c_bindings/my_timer.h` with `nimble genbindings_c` (from the
  repo root) if the library's API changes.
