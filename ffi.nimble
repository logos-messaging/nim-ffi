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

task genbindings_example, "Generate Rust bindings for the timer example":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain --nimMainPrefix:libmy_timer -d:ffiGenBindings -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc & " --app:lib --noMain --nimMainPrefix:libmy_timer -d:ffiGenBindings -o:/dev/null examples/timer/timer.nim"

task genbindings_rust, "Generate Rust bindings for the timer example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=rust" &
    " -d:ffiOutputDir=examples/timer/rust_bindings" &
    " -d:ffiNimSrcRelPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=rust" &
    " -d:ffiOutputDir=examples/timer/rust_bindings" &
    " -d:ffiNimSrcRelPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"

task genbindings_cpp, "Generate C++ bindings for the timer example":
  exec "nim c " & nimFlagsOrc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/timer/cpp_bindings" &
    " -d:ffiNimSrcRelPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
  exec "nim c " & nimFlagsRefc &
    " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/timer/cpp_bindings" &
    " -d:ffiNimSrcRelPath=../timer.nim" &
    " -o:/dev/null examples/timer/timer.nim"
