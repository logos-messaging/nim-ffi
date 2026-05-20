version = "0.1.0"
packageName = "timer"
author = "Institute of Free Technology"
description = "Example Nim timer library using nim-ffi"
license = "MIT or Apache License 2.0"

requires "nim >= 2.2.4"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "https://github.com/logos-messaging/nim-ffi >= 0.2.0"

const nimFlags = "--mm:orc -d:chronicles_log_level=WARN"

task build, "Compile the timer library":
  exec "nim c " & nimFlags &
    " --app:lib --noMain --nimMainPrefix:libmy_timer timer.nim"

task genbindings_rust, "Generate Rust bindings for the timer example":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=rust" & " -d:ffiOutputDir=rust_bindings" &
    " -d:ffiSrcPath=timer.nim" & " -o:/dev/null timer.nim"

task genbindings_cpp, "Generate C++ bindings for the timer example":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libmy_timer" &
    " -d:ffiGenBindings -d:targetLang=cpp" & " -d:ffiOutputDir=cpp_bindings" &
    " -d:ffiSrcPath=timer.nim" & " -o:/dev/null timer.nim"
