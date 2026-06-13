# iOS example — Swift over the native C ABI

A SwiftPM package that wraps the timer library's **native** (zero-serialization)
C ABI behind an idiomatic Swift class, `TimerNode`. The library is cross-compiled
to a static `.xcframework` and consumed from Swift; struct returns come back as
typed Swift values.

```swift
let node = try TimerNode(name: "my-app")
print(try node.version())                 // "nim-timer v0.1.0"
let r = try node.echo("hello", delayMs: 5) // EchoResult
print(r.echoed, r.timerName)
```

## Layout

| Path | Description |
|------|-------------|
| `build-xcframework.sh` | Cross-compiles the Nim lib to `MyTimer.xcframework` (ios-arm64 device, ios-arm64 simulator, macos-arm64) and bundles the C headers + module map. |
| `cheaders/` | The native C header (`my_timer.h`), CBOR header, and `module.modulemap` (module `CMyTimer`). |
| `Sources/MyTimer/MyTimer.swift` | The Swift wrapper. Bridges the async FFI-thread callback to a synchronous Swift API with a semaphore; reads the typed `EchoResponse` struct out of the callback. |
| `Package.swift` | SwiftPM: a binary target (the xcframework) + the Swift wrapper + tests. |
| `Tests/` | Unit tests, runnable on the host via the macOS slice. |

## Build & test

```sh
cd examples/timer/ios
./build-xcframework.sh     # builds the 3 slices into MyTimer.xcframework
swift test                 # runs on the host (macos-arm64 slice)
```

`build-xcframework.sh` assembles the `.xcframework` directly (no
`xcodebuild -create-xcframework`), so it works in headless / CI environments.
The **macos-arm64** slice exists only so the wrapper is testable with
`swift test`; real iOS deployment uses the **ios-arm64** (device) and
**ios-arm64-simulator** slices.

## Use it in an iOS app

1. Run `./build-xcframework.sh`.
2. Add this directory as a local Swift package (Xcode → *Add Package
   Dependencies… → Add Local…*), or depend on it in your own `Package.swift`.
3. `import MyTimer` and use `TimerNode`.

## Notes

- This is the **native, same-process** path — the app links the library directly.
  The CBOR ABI is for inter-process communication only (see [`../ipc`](../ipc)).
- Each call is dispatched on the library's background FFI thread; `TimerNode`
  blocks on a semaphore until the result callback fires. A struct return (e.g.
  `EchoResponse`) is read inside the callback — it is valid only for the
  callback's lifetime — and copied into the returned Swift value.
- Regenerate `cheaders/my_timer.h` from the repo root with `nimble genbindings_c`
  if the library's API changes.
