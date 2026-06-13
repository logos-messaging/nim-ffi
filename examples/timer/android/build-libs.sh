#!/usr/bin/env bash
# Cross-compile the native libraries for Android and stage them under
# src/main/jniLibs/<abi>/, so Gradle packages them into the AAR/APK:
#   - libmy_timer.so      the Nim timer library (native C ABI)
#   - libmy_timer_jni.so  the JNI shim that bridges it to Kotlin
#
# Requires the Android NDK (set ANDROID_NDK_ROOT, or it falls back to the
# Homebrew location) and Nim. Builds arm64-v8a + x86_64 by default (real devices
# and the emulator); add rows to the table below for more ABIs.
#
#   ./build-libs.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
NIM_SRC="$REPO_ROOT/examples/timer/timer.nim"
HDR_DIR="$REPO_ROOT/examples/timer/c_bindings"
JNILIBS="$HERE/src/main/jniLibs"

NDK="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-ndk}"
API="${ANDROID_API:-21}"
HOST_TAG="$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)"
TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"

build_abi() { # <abi> <nim-cpu> <ndk-triple>
  local abi="$1" cpu="$2" triple="$3"
  local cc="$TC/bin/${triple}${API}-clang"
  local out="$JNILIBS/$abi"
  echo ">> $abi"
  mkdir -p "$out"
  # 1) the Nim library (native C ABI)
  ( cd "$REPO_ROOT" && nim c --mm:orc -d:release -d:chronicles_log_level=WARN \
      --threads:on --os:android --cpu:"$cpu" --cc:clang \
      --clang.exe:"$cc" --clang.linkerexe:"$cc" \
      --app:lib --noMain --nimMainPrefix:libmy_timer \
      --nimcache:"$HERE/.nimcache/$abi" \
      -o:"$out/libmy_timer.so" "$NIM_SRC" >/dev/null )
  # 2) the JNI shim, linked against the Nim library
  "$cc" -shared -fPIC -O2 -I"$HDR_DIR" "$HERE/jni/my_timer_jni.c" \
      -L"$out" -lmy_timer -o "$out/libmy_timer_jni.so"
  echo "   $(cd "$out" && echo *.so)"
}

test -x "$TC/bin/aarch64-linux-android${API}-clang" \
  || { echo "NDK not found at $NDK (set ANDROID_NDK_ROOT)"; exit 1; }

rm -rf "$JNILIBS"
build_abi arm64-v8a arm64 aarch64-linux-android
build_abi x86_64    amd64 x86_64-linux-android
echo ">> done -> src/main/jniLibs/"
