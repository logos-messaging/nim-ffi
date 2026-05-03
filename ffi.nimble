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

const nimFlags = "--mm:orc -d:chronicles_log_level=WARN"

task buildffi, "Compile the library":
  exec "nim c " & nimFlags & " --app:lib --noMain ffi.nim"

task test, "Run all tests":
  exec "nim c -r " & nimFlags & " tests/test_alloc.nim"
  exec "nim c -r " & nimFlags & " tests/test_serial.nim"
  exec "nim c -r " & nimFlags & " tests/test_ffi_context.nim"

task test_alloc, "Run alloc unit tests":
  exec "nim c -r " & nimFlags & " tests/test_alloc.nim"

task test_ffi, "Run FFI context integration tests":
  exec "nim c -r " & nimFlags & " tests/test_ffi_context.nim"

task test_serial, "Run serial unit tests":
  exec "nim c -r " & nimFlags & " tests/test_serial.nim"

task genbindings_rust, "Generate Rust bindings for the nim_timer example":
  exec "nim c " & nimFlags &
    " --app:lib --noMain --nimMainPrefix:libnimtimer" &
    " -d:ffiGenBindings -d:targetLang=rust" &
    " -d:ffiOutputDir=examples/nim_timer/rust_bindings" &
    " -d:ffiNimSrcRelPath=../nim_timer.nim" &
    " -o:/dev/null examples/nim_timer/nim_timer.nim"

task genbindings_cpp, "Generate C++ bindings for the nim_timer example":
  exec "nim c " & nimFlags &
    " --app:lib --noMain --nimMainPrefix:libnimtimer" &
    " -d:ffiGenBindings -d:targetLang=cpp" &
    " -d:ffiOutputDir=examples/nim_timer/cpp_bindings" &
    " -d:ffiNimSrcRelPath=../nim_timer.nim" &
    " -o:/dev/null examples/nim_timer/nim_timer.nim"
