# ffi.nimble

version = "0.1.3"
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

const unitTests = @[
  "test_alloc",
  "test_ffi_context",
  "test_gc_compat",
  "test_serial",
  "test_ctx_validation",
  "test_nim_native_api",
  "test_meta",
  "test_string_helpers",
  "test_wire_compat",
  "test_cddl_codegen",
]

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
    exec "nim c -r " & flags & " tests/unit/test_alloc.nim"
    exec "nim c -r " & flags & " tests/unit/test_ffi_context.nim"
    exec "nim c -r " & flags & " tests/unit/test_gc_compat.nim"
    exec "nim c -r " & flags & " tests/unit/test_serial.nim"
    exec "nim c -r " & flags & " tests/unit/test_ctx_validation.nim"
    exec "nim c -r " & flags & " tests/unit/test_nim_native_api.nim"
    exec "nim c -r " & flags & " tests/unit/test_meta.nim"
    exec "nim c -r " & flags & " tests/unit/test_string_helpers.nim"
    exec "nim c -r " & flags & " tests/unit/test_wire_compat.nim"
    exec "nim c -r " & flags & " tests/unit/test_cddl_codegen.nim"

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
  exec "nimble genbindings_cpp"
  exec "cmake -S tests/e2e/cpp -B tests/e2e/cpp/build"
  exec "cmake --build tests/e2e/cpp/build"
  exec "ctest --test-dir tests/e2e/cpp/build --output-on-failure"

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
  exec "nimble genbindings_cpp"
  exec "cmake -S tests/e2e/cpp -B tests/e2e/cpp/build" &
       " -DNIM_FFI_MM=" & mm &
       " -DNIM_FFI_SANITIZER=" & san
  exec "cmake --build tests/e2e/cpp/build -j"
  exec "ctest --test-dir tests/e2e/cpp/build --output-on-failure"

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
