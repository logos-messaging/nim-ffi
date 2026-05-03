version = "0.1.0"
packageName = "nimtimer"
author = "Institute of Free Technology"
description = "Example Nim timer library using nim-ffi"
license = "MIT or Apache License 2.0"

requires "nim >= 2.2.4"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "https://github.com/logos-messaging/nim-ffi >= 0.1.3"

const nimFlags = "--mm:orc -d:chronicles_log_level=WARN"

task build, "Compile the nimtimer library":
  exec "nim c " & nimFlags &
    " --app:lib --noMain --nimMainPrefix:libnimtimer nim_timer.nim"

task genbindings_rust, "Generate Rust bindings for the nimtimer example":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libnimtimer" &
    " -d:ffiGenBindings -d:targetLang=rust" & " -d:ffiOutputDir=rust_bindings" &
    " -d:ffiNimSrcRelPath=nim_timer.nim" & " -o:/dev/null nim_timer.nim"

task genbindings_cpp, "Generate C++ bindings for the nimtimer example":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libnimtimer" &
    " -d:ffiGenBindings -d:targetLang=cpp" & " -d:ffiOutputDir=cpp_bindings" &
    " -d:ffiNimSrcRelPath=nim_timer.nim" & " -o:/dev/null nim_timer.nim"
