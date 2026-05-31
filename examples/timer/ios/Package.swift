// swift-tools-version:5.9
import PackageDescription

// SwiftPM package wrapping the timer library for iOS (and macOS, so the Swift
// wrapper is testable on the host with `swift test`).
//
// `MyTimer.xcframework` is produced by ./build-xcframework.sh and bundles the
// static library for ios-arm64 (device), ios-arm64-simulator, and macos-arm64,
// each with the C headers + module map. Run the build script before
// `swift build` / `swift test`.
let package = Package(
    name: "MyTimer",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [
        .library(name: "MyTimer", targets: ["MyTimer"])
    ],
    targets: [
        .binaryTarget(name: "CMyTimer", path: "MyTimer.xcframework"),
        .target(name: "MyTimer", dependencies: ["CMyTimer"]),
        .testTarget(name: "MyTimerTests", dependencies: ["MyTimer"]),
    ]
)
