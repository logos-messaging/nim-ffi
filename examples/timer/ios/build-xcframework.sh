#!/usr/bin/env bash
# Build MyTimer.xcframework from the Nim timer library:
#   - ios-arm64            (device)
#   - ios-arm64-simulator  (Apple-silicon simulator)
#   - macos-arm64          (so the Swift wrapper is testable with `swift test`)
#
# Each slice is a static library cross-compiled by Nim with the matching SDK,
# then bundled with the C headers + module map. Requires Xcode + Nim.
#
#   ./build-xcframework.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NIM_SRC="$REPO_ROOT/examples/timer/timer.nim"
STAGE="$HERE/.build-slices"
OUT="$HERE/MyTimer.xcframework"

CLANG="$(xcrun -f clang)"
COMMON_NIM=(--mm:orc -d:release -d:chronicles_log_level=WARN --threads:on
            --os:macosx --cpu:arm64 --app:staticlib --noMain
            --nimMainPrefix:libmy_timer --cc:clang
            "--clang.exe:$CLANG" "--clang.linkerexe:$CLANG")

# build_slice <name> <sdk> <min-flag>
build_slice() {
  local name="$1" sdk="$2" minflag="$3"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local dir="$STAGE/$name"
  mkdir -p "$dir"
  echo ">> building slice: $name ($sdk)"
  ( cd "$REPO_ROOT" && nim c "${COMMON_NIM[@]}" \
      --nimcache:"$dir/nimcache" \
      --passC:"-isysroot $sysroot -arch arm64 $minflag" \
      --passL:"-isysroot $sysroot -arch arm64 $minflag" \
      -o:"$dir/libmy_timer.a" "$NIM_SRC" >/dev/null )
}

rm -rf "$STAGE" "$OUT"
build_slice device    iphoneos          "-miphoneos-version-min=13.0"
build_slice simulator iphonesimulator   "-mios-simulator-version-min=13.0"
build_slice macos     macosx            "-mmacosx-version-min=12.0"

echo ">> assembling $OUT"
# Assemble the .xcframework by hand (a directory + Info.plist) rather than via
# `xcodebuild -create-xcframework` — same on-disk format, but no dependency on a
# working Simulator toolchain, so it builds in headless / CI environments too.
add_slice() { # <stage-name> <library-identifier>
  local dir="$OUT/$2"
  mkdir -p "$dir/Headers"
  cp "$STAGE/$1/libmy_timer.a" "$dir/libmy_timer.a"
  cp "$HERE/cheaders/"* "$dir/Headers/"
}
mkdir -p "$OUT"
add_slice device    ios-arm64
add_slice simulator ios-arm64-simulator
add_slice macos     macos-arm64

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>LibraryIdentifier</key><string>ios-arm64</string>
      <key>LibraryPath</key><string>libmy_timer.a</string>
      <key>HeadersPath</key><string>Headers</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
    </dict>
    <dict>
      <key>LibraryIdentifier</key><string>ios-arm64-simulator</string>
      <key>LibraryPath</key><string>libmy_timer.a</string>
      <key>HeadersPath</key><string>Headers</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
      <key>SupportedPlatformVariant</key><string>simulator</string>
    </dict>
    <dict>
      <key>LibraryIdentifier</key><string>macos-arm64</string>
      <key>LibraryPath</key><string>libmy_timer.a</string>
      <key>HeadersPath</key><string>Headers</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>macos</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST

echo ">> done. Slices:"
ls "$OUT"
