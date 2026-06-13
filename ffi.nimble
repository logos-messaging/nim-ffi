# ffi.nimble

version = "0.2.0"
author = "Institute of Free Technology"
description = "FFI framework with custom header generation"
license = "MIT or Apache License 2.0"

packageName = "ffi"

requires "nim >= 2.2.4"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "cbor_serialization"

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
    " --passC:-fsanitize=address,undefined" &
    " --passC:-fno-sanitize-recover=all" &
    " --passC:-fno-omit-frame-pointer" &
    " --passC:-g" &
    " --passL:-fsanitize=address,undefined"
  of "tsan":
    " --passC:-fsanitize=thread" &
    " --passC:-fno-omit-frame-pointer" &
    " --passC:-g" &
    " --passC:-O1" &
    " --passL:-fsanitize=thread"
  else:
    raise newException(ValueError, "unknown NIM_FFI_SAN: " & san)

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

task test_cpp_e2e, "Build and run the C++ end-to-end tests for the timer example":
  # Regenerate the C++ bindings so the suite always runs against fresh codegen.
  runOrQuit "nimble genbindings_cpp"
  runOrQuit "nimble genbindings_cpp_echo"
  runOrQuit "cmake -S tests/e2e/cpp -B tests/e2e/cpp/build"
  runOrQuit "cmake --build tests/e2e/cpp/build"
  runOrQuit "ctest --test-dir tests/e2e/cpp/build --output-on-failure"

task test_sanitized, "Run all unit tests under a sanitizer (NIM_FFI_SAN) and mm (NIM_FFI_MM)":
  let san = getEnv("NIM_FFI_SAN", "none")
  let mm  = getEnv("NIM_FFI_MM",  "")
  let extra = sanFlags(san)
  let modes =
    if mm == "orc": @[nimFlagsOrc]
    elif mm == "refc": @[nimFlagsRefc]
    else: @[nimFlagsOrc, nimFlagsRefc]
  if san == "tsan":
    let suppPath = thisDir() & "/tsan.supp"
    let existing = getEnv("TSAN_OPTIONS")
    if existing == "":
      putEnv("TSAN_OPTIONS", "suppressions=" & suppPath)
    elif "suppressions=" notin existing:
      putEnv("TSAN_OPTIONS", existing & ":suppressions=" & suppPath)
  for flags in modes:
    for t in unitTests:
      exec "nim c -r " & flags & extra & " tests/unit/" & t & ".nim"

task test_cpp_e2e_sanitized, "Build and run the C++ e2e tests with a sanitizer (NIM_FFI_SAN) and mm (NIM_FFI_MM)":
  let mm  = getEnv("NIM_FFI_MM",  "orc")
  let san = getEnv("NIM_FFI_SAN", "none")
  runOrQuit "nimble genbindings_cpp"
  runOrQuit "nimble genbindings_cpp_echo"
  runOrQuit "cmake -S tests/e2e/cpp -B tests/e2e/cpp/build" &
       " -DNIM_FFI_MM=" & mm &
       " -DNIM_FFI_SANITIZER=" & san
  runOrQuit "cmake --build tests/e2e/cpp/build -j"
  runOrQuit "ctest --test-dir tests/e2e/cpp/build --output-on-failure"

task genbindings_example, "Generate Rust bindings for the timer example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libmy_timer -d:ffiGenBindings -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libmy_timer -d:ffiGenBindings -o:/dev/null examples/timer/timer.nim"

task genbindings_rust, "Generate Rust bindings for the timer example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=rust" &
    " -d:ffiOutputDir=examples/timer/rust_bindings" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=rust" &
    " -d:ffiOutputDir=examples/timer/rust_bindings" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_c, "Generate C bindings for the timer example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=c" &
    " -d:ffiOutputDir=examples/timer/c_bindings" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=c" &
    " -d:ffiOutputDir=examples/timer/c_bindings" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_go, "Generate Go (cgo) bindings for the timer example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=go" &
    " -d:ffiOutputDir=examples/timer/go_bindings" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
  # The codegen emits compilable but not column-aligned Go; gofmt finalizes it
  # (cgo struct-field alignment etc.). Skipped silently if gofmt isn't present.
  if findExe("gofmt").len > 0:
    exec "gofmt -w examples/timer/go_bindings/my_timer.go"

task genbindings_kotlin, "Generate the Kotlin/JNI wrapper for the Android timer example":
  # Emits src/main/kotlin/.../MyTimerNode.kt + jni/my_timer_jni.c over the native
  # C ABI. The C headers the shim includes come from `nimble genbindings_c`; run
  # that too if the library's types or procs changed.
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=kotlin" &
    " -d:ffiOutputDir=examples/timer/android" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_cddl, "Generate CDDL schema for the timer example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libtimer" &
    " -d:ffiGenBindings -d:targetLang=cddl" &
    " -d:ffiOutputDir=examples/timer/cddl_bindings" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_cpp, "Generate C++ bindings for the timer example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/timer/cpp_bindings" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/timer/cpp_bindings" &
    " -d:ffiSrcPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_cpp_echo, "Generate C++ bindings for the echo example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/echo/cpp_bindings" &
    " -d:ffiSrcPath=../echo.nim" &
    " -o:/dev/null examples/echo/echo.nim"
  exec "nim c " & nimFlagsRefc &
    " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/echo/cpp_bindings" &
    " -d:ffiSrcPath=../echo.nim" &
    " -o:/dev/null examples/echo/echo.nim"

task check_bindings_rust, "Verify checked-in Rust bindings match Nim source":
  exec "nimble genbindings_rust"
  exec "git diff --exit-code --" &
    " examples/timer/rust_bindings/Cargo.toml" &
    " examples/timer/rust_bindings/build.rs" &
    " examples/timer/rust_bindings/src"

task check_bindings_cpp, "Verify checked-in C++ bindings match Nim source":
  exec "nimble genbindings_cpp"
  exec "git diff --exit-code --" &
    " examples/timer/cpp_bindings/my_timer.hpp" &
    " examples/timer/cpp_bindings/CMakeLists.txt"

task check_bindings, "Verify all checked-in example bindings match Nim source":
  exec "nimble check_bindings_rust"
  exec "nimble check_bindings_cpp"
