# ffi.nimble

version = "0.2.0"
author = "Institute of Free Technology"
description = "FFI framework with custom header generation"
license = "MIT or Apache License 2.0"

packageName = "ffi"

requires "nim >= 2.2.6"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "cbor_serialization == 0.3.0"

const nimFlagsOrc = "--mm:orc -d:chronicles_log_level=WARN"
const nimFlagsRefc = "--mm:refc -d:chronicles_log_level=WARN"

import std/[algorithm, os, strutils]

proc discoverUnitTests(): seq[string] =
  # `listFiles` returns both .nim sources and any compiled binaries left in
  # the dir from prior local runs — filter to .nim so we don't run a test
  # twice (and don't try to `nim c -r` a stale binary).
  var names: seq[string] = @[]
  for path in listFiles(thisDir() / "tests/unit"):
    if path.endsWith(".nim"):
      let name = path.extractFilename.changeFileExt("")
      if name.startsWith("test_"):
        names.add(name)
  names.sort()
  return names

let unitTests = discoverUnitTests()

proc runOrQuit(cmd: string) =
  # Workaround for newer nimble (shipping with Nim 2.2.10+) printing the
  # OSError from a failed `exec` but exiting 0, which causes CI to report
  # green on actual build/test failures. Echo the command first so the log
  # makes clear which step failed.
  try:
    exec cmd
  except OSError as e:
    echo "command failed: ", cmd
    echo "error: ", e.msg
    quit(QuitFailure)

proc sanFlags(san: string): string =
  # Each --passC / --passL adds one literal flag to the C compiler / linker
  # invocation — avoids any quoting ambiguity that arises from putting
  # space-separated flags inside a single --passC argument.
  #
  # `asan-ubsan` enables LeakSanitizer too: ASan includes LSan, so leaks are
  # reported when ASAN_OPTIONS=detect_leaks=1 (set by the sanitizer CI job).
  case san
  of "none", "":
    ""
  of "asan-ubsan":
    " --passC:-fsanitize=address,undefined" & " --passC:-fno-sanitize-recover=all" &
      " --passC:-fno-omit-frame-pointer" & " --passC:-g" &
      " --passL:-fsanitize=address,undefined"
  of "tsan":
    " --passC:-fsanitize=thread" & " --passC:-fno-omit-frame-pointer" & " --passC:-g" &
      " --passC:-O1" & " --passL:-fsanitize=thread"
  else:
    raise newException(ValueError, "unknown NIM_FFI_SAN: " & san)

proc mmModes(): seq[string] =
  ## Memory-management modes to build under, selected by NIM_FFI_MM (empty = both).
  case getEnv("NIM_FFI_MM", "")
  of "orc":
    @[nimFlagsOrc]
  of "refc":
    @[nimFlagsRefc]
  else:
    @[nimFlagsOrc, nimFlagsRefc]

proc applyTsanSuppressions() =
  ## Adds tsan.supp to TSAN_OPTIONS without clobbering options the CI job set.
  let suppPath = thisDir() & "/tsan.supp"
  let existing = getEnv("TSAN_OPTIONS")
  if existing == "":
    putEnv("TSAN_OPTIONS", "suppressions=" & suppPath)
  elif "suppressions=" notin existing:
    putEnv("TSAN_OPTIONS", existing & ":suppressions=" & suppPath)

proc removeStaleEchoLib() =
  ## The CBOR and `abi = c` echo e2e suites both compile examples/echo/echo.nim
  ## to the same repo-root `libecho.so`, differing only by `-d:ffiEchoAbiC`.
  ## CMake keys the dylib rebuild on echo.nim's mtime, not the ABI flag, so a
  ## `libecho.so` left by an earlier CBOR e2e step is silently reused by the
  ## abi=c build — the flat-struct C caller then reaches the CBOR entry points
  ## (wrong arity/ABI) and segfaults. Delete it first to force a fresh rebuild
  ## with the right ABI.
  for name in ["libecho.so", "libecho.dylib", "echo.dll"]:
    let path = thisDir() / name
    if fileExists(path):
      rmFile(path)

task buildffi, "Compile the library":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain ffi.nim"

task test, "Run all tests under --mm:orc and --mm:refc":
  for flags in [nimFlagsOrc, nimFlagsRefc]:
    for t in unitTests:
      exec "nim c -r " & flags & " tests/unit/" & t & ".nim"

task test_alloc, "Run alloc unit tests under --mm:orc and --mm:refc":
  exec "nim c -r " & nimFlagsOrc & " tests/unit/test_alloc.nim"
  exec "nim c -r " & nimFlagsRefc & " tests/unit/test_alloc.nim"

task test_ffi, "Run FFI context integration tests under --mm:orc and --mm:refc":
  exec "nim c -r " & nimFlagsOrc & " tests/unit/test_ffi_context.nim"
  exec "nim c -r " & nimFlagsRefc & " tests/unit/test_ffi_context.nim"

task test_serial, "Run CBOR codec unit tests":
  exec "nim c -r " & nimFlagsOrc & " tests/unit/test_serial.nim"
  exec "nim c -r " & nimFlagsRefc & " tests/unit/test_serial.nim"

task bench_codec, "Microbenchmark: cbor vs c (cwire) wire-format codecs":
  # Built with -d:danger so the numbers reflect optimized codegen, not the
  # debug build. Not part of `test` — timing is a measurement, not a gate.
  exec "nim c -r " & nimFlagsOrc & " -d:danger tests/bench/bench_codec.nim"

task bench_ffi_submit,
  "Concurrent-submit stress + scaling gate for sendRequestToFFIThread":
  # Honors NIM_FFI_SAN / NIM_FFI_MM like test_sanitized so CI drives it under
  # asan-ubsan and tsan; FFI_SUBMIT_PER_THREAD sets per-thread volume.
  let san = getEnv("NIM_FFI_SAN", "none")
  let extra = sanFlags(san)
  if san == "tsan":
    applyTsanSuppressions()
  for flags in mmModes():
    exec "nim c -r " & flags & " -d:danger" & extra & " tests/bench/bench_ffi_submit.nim"

task test_cpp_e2e, "Build and run the C++ end-to-end tests for the timer example":
  # Regenerate the C++ bindings so the suite always runs against fresh codegen.
  runOrQuit "nimble genbindings_cpp"
  runOrQuit "nimble genbindings_cpp_echo"
  runOrQuit "cmake -S tests/e2e/cpp -B tests/e2e/cpp/build"
  runOrQuit "cmake --build tests/e2e/cpp/build --config Debug"
  # `-C Debug` is required on Windows multi-config generators because
  # gtest_discover_tests(PRE_TEST) loads per-config include files; harmless on
  # single-config generators (Make/Ninja) on Linux/macOS.
  runOrQuit "ctest --test-dir tests/e2e/cpp/build --output-on-failure -C Debug"

task test_c_e2e, "Build and run the C end-to-end tests for the timer example":
  # Regenerate the C bindings so the suite always runs against fresh codegen.
  runOrQuit "nimble genbindings_c"
  runOrQuit "cmake -S tests/e2e/c -B tests/e2e/c/build"
  runOrQuit "cmake --build tests/e2e/c/build --config Debug"
  runOrQuit "ctest --test-dir tests/e2e/c/build --output-on-failure -C Debug"

task test_c_abi_e2e, "Build and run the CBOR-free abi=c C end-to-end test (echo)":
  # Regenerate the abi=c bindings so the suite always runs against fresh codegen.
  runOrQuit "nimble genbindings_c_abi_echo"
  removeStaleEchoLib()
  runOrQuit "cmake -S tests/e2e/c_abi -B tests/e2e/c_abi/build"
  runOrQuit "cmake --build tests/e2e/c_abi/build --config Debug"
  runOrQuit "ctest --test-dir tests/e2e/c_abi/build --output-on-failure -C Debug"

task test_sanitized,
  "Run all unit tests under a sanitizer (NIM_FFI_SAN) and mm (NIM_FFI_MM)":
  let san = getEnv("NIM_FFI_SAN", "none")
  let extra = sanFlags(san)
  if san == "tsan":
    applyTsanSuppressions()
  for flags in mmModes():
    for t in unitTests:
      exec "nim c -r " & flags & extra & " tests/unit/" & t & ".nim"

task test_cpp_e2e_sanitized,
  "Build and run the C++ e2e tests with a sanitizer (NIM_FFI_SAN) and mm (NIM_FFI_MM)":
  let mm = getEnv("NIM_FFI_MM", "orc")
  let san = getEnv("NIM_FFI_SAN", "none")
  runOrQuit "nimble genbindings_cpp"
  runOrQuit "nimble genbindings_cpp_echo"
  runOrQuit "cmake -S tests/e2e/cpp -B tests/e2e/cpp/build" & " -DNIM_FFI_MM=" & mm &
    " -DNIM_FFI_SANITIZER=" & san
  runOrQuit "cmake --build tests/e2e/cpp/build --config Debug -j"
  runOrQuit "ctest --test-dir tests/e2e/cpp/build --output-on-failure -C Debug"

task test_c_e2e_sanitized,
  "Build and run the C e2e tests with a sanitizer (NIM_FFI_SAN) and mm (NIM_FFI_MM)":
  let mm = getEnv("NIM_FFI_MM", "orc")
  let san = getEnv("NIM_FFI_SAN", "none")
  runOrQuit "nimble genbindings_c"
  runOrQuit "cmake -S tests/e2e/c -B tests/e2e/c/build" & " -DNIM_FFI_MM=" & mm &
    " -DNIM_FFI_SANITIZER=" & san
  runOrQuit "cmake --build tests/e2e/c/build --config Debug -j"
  runOrQuit "ctest --test-dir tests/e2e/c/build --output-on-failure -C Debug"

task test_c_abi_e2e_sanitized,
  "Build and run the abi=c C e2e test with a sanitizer (NIM_FFI_SAN)":
  let san = getEnv("NIM_FFI_SAN", "none")
  runOrQuit "nimble genbindings_c_abi_echo"
  removeStaleEchoLib()
  runOrQuit "cmake -S tests/e2e/c_abi -B tests/e2e/c_abi/build" & " -DNIM_FFI_SANITIZER=" &
    san
  runOrQuit "cmake --build tests/e2e/c_abi/build --config Debug -j"
  runOrQuit "ctest --test-dir tests/e2e/c_abi/build --output-on-failure -C Debug"

task genbindings_example, "Generate Rust bindings for the timer example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer -d:ffiGenBindings -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer -d:ffiGenBindings -o:/dev/null examples/timer/timer.nim"

task genbindings_rust, "Generate Rust bindings for the timer example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=rust" &
    " -d:ffiOutputDir=examples/timer/rust_bindings" & " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=rust" &
    " -d:ffiOutputDir=examples/timer/rust_bindings" & " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_cddl, "Generate CDDL schema for the timer example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libtimer" &
    " -d:ffiGenBindings -d:targetLang=cddl" &
    " -d:ffiOutputDir=examples/timer/cddl_bindings" & " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_cpp, "Generate C++ bindings for the timer example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/timer/cpp_bindings" & " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/timer/cpp_bindings" & " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_cpp_skeleton, "Generate C++ bindings for the skeleton example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libskeleton" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/skeleton/cpp_bindings" & " -d:ffiSrcPath=../skeleton.nim" &
    " -o:/dev/null examples/skeleton/skeleton.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libskeleton" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/skeleton/cpp_bindings" & " -d:ffiSrcPath=../skeleton.nim" &
    " -o:/dev/null examples/skeleton/skeleton.nim"

task genbindings_cpp_echo, "Generate C++ bindings for the echo example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/echo/cpp_bindings" & " -d:ffiSrcPath=../echo.nim" &
    " -o:/dev/null examples/echo/echo.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/echo/cpp_bindings" & " -d:ffiSrcPath=../echo.nim" &
    " -o:/dev/null examples/echo/echo.nim"

task genbindings_c, "Generate C bindings for the timer example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=c" & " -d:ffiOutputDir=examples/timer/c_bindings" &
    " -d:ffiSrcPath=../timer.nim" & " -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=c" & " -d:ffiOutputDir=examples/timer/c_bindings" &
    " -d:ffiSrcPath=../timer.nim" & " -o:/dev/null examples/timer/timer.nim"

task genbindings_c_echo, "Generate C bindings for the echo example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiGenBindings -d:targetLang=c" & " -d:ffiOutputDir=examples/echo/c_bindings" &
    " -d:ffiSrcPath=../echo.nim" & " -o:/dev/null examples/echo/echo.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiGenBindings -d:targetLang=c" & " -d:ffiOutputDir=examples/echo/c_bindings" &
    " -d:ffiSrcPath=../echo.nim" & " -o:/dev/null examples/echo/echo.nim"

task genbindings_c_abi_echo, "Generate CBOR-free abi=c C bindings for the echo example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiEchoAbiC -d:ffiGenBindings -d:targetLang=c_abi" &
    " -d:ffiOutputDir=examples/echo/c_abi_bindings" & " -d:ffiSrcPath=../echo.nim" &
    " -o:/dev/null examples/echo/echo.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiEchoAbiC -d:ffiGenBindings -d:targetLang=c_abi" &
    " -d:ffiOutputDir=examples/echo/c_abi_bindings" & " -d:ffiSrcPath=../echo.nim" &
    " -o:/dev/null examples/echo/echo.nim"

task check_bindings_rust, "Verify checked-in Rust bindings match Nim source":
  exec "nimble genbindings_rust"
  exec "git diff --exit-code --" & " examples/timer/rust_bindings/Cargo.toml" &
    " examples/timer/rust_bindings/build.rs" & " examples/timer/rust_bindings/src"

task check_bindings_cpp, "Verify checked-in C++ bindings match Nim source":
  exec "nimble genbindings_cpp"
  exec "nimble genbindings_cpp_echo"
  exec "git diff --exit-code --" & " examples/timer/cpp_bindings/my_timer.hpp" &
    " examples/timer/cpp_bindings/CMakeLists.txt" &
    " examples/echo/cpp_bindings/echo.hpp" & " examples/echo/cpp_bindings/CMakeLists.txt"

task check_bindings_c, "Verify checked-in C bindings match Nim source":
  exec "nimble genbindings_c"
  exec "nimble genbindings_c_echo"
  exec "git diff --exit-code --" & " examples/timer/c_bindings/my_timer.h" &
    " examples/timer/c_bindings/nim_ffi_prelude.h" &
    " examples/timer/c_bindings/nim_ffi_cbor.h" &
    " examples/timer/c_bindings/CMakeLists.txt" & " examples/echo/c_bindings/echo.h" &
    " examples/echo/c_bindings/nim_ffi_prelude.h" &
    " examples/echo/c_bindings/nim_ffi_cbor.h" &
    " examples/echo/c_bindings/CMakeLists.txt"

task check_bindings_c_abi, "Verify checked-in abi=c C bindings match Nim source":
  exec "nimble genbindings_c_abi_echo"
  exec "git diff --exit-code --" & " examples/echo/c_abi_bindings/echo.h" &
    " examples/echo/c_abi_bindings/CMakeLists.txt"

task check_bindings_skeleton,
  "Verify checked-in skeleton template bindings match Nim source":
  exec "nimble genbindings_cpp_skeleton"
  exec "git diff --exit-code --" & " examples/skeleton/cpp_bindings/skeleton.hpp" &
    " examples/skeleton/cpp_bindings/CMakeLists.txt"

task check_bindings, "Verify all checked-in example bindings match Nim source":
  exec "nimble check_bindings_rust"
  exec "nimble check_bindings_cpp"
  exec "nimble check_bindings_c"
  exec "nimble check_bindings_c_abi"
  exec "nimble check_bindings_skeleton"
