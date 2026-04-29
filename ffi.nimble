# ffi.nimble

version = "0.1.3"
author = "Institute of Free Technology"
description = "FFI framework with custom header generation"
license = "MIT or Apache License 2.0"

packageName   = "ffi"

requires "nim >= 2.2.4"
requires "chronos"
requires "chronicles"
requires "taskpools"

const nimFlags = "--mm:orc -d:chronicles_log_level=WARN"

task buildffi, "Compile the library":
  exec "nim c " & nimFlags & " --app:lib --noMain ffi.nim"

task test, "Run all tests":
  exec "nim c -r " & nimFlags & " tests/test_alloc.nim"
  exec "nim c -r " & nimFlags & " tests/test_ffi_context.nim"

task test_alloc, "Run alloc unit tests":
  exec "nim c -r " & nimFlags & " tests/test_alloc.nim"

task test_ffi, "Run FFI context integration tests":
  exec "nim c -r " & nimFlags & " tests/test_ffi_context.nim"
