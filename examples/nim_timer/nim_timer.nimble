version = "0.1.0"
packageName = "nimtimer"
author = "Institute of Free Technology"
description = "Example Nim timer library using nim-ffi"
license = "MIT or Apache License 2.0"

requires "nim >= 2.2.4"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "ffi >= 0.1.3"

# Build the example library and optionally generate bindings.
task build, "Compile the nimtimer library":
  exec "nim c --app:lib --noMain --nimMainPrefix:libnimtimer -d:ffiGenBindings -d:targetLang=rust nim_timer.nim"

task genbindings_rust, "Generate Rust bindings for the nimtimer example":
  exec "nim c --app:lib --noMain --nimMainPrefix:libnimtimer -d:ffiGenBindings -d:targetLang=rust nim_timer.nim"

task genbindings_cpp, "Generate C++ bindings for the nimtimer example":
  exec "nim c --app:lib --noMain --nimMainPrefix:libnimtimer -d:ffiGenBindings -d:targetLang=cpp nim_timer.nim"
