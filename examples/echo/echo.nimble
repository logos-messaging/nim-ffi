version = "0.1.0"
packageName = "echo"
author = "Institute of Free Technology"
description =
  "Second nim-ffi example library, used as the cross-library partner of the timer example in C++ e2e tests"
license = "MIT or Apache License 2.0"

requires "nim >= 2.2.6"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "https://github.com/logos-messaging/nim-ffi >= 0.2.0"

const nimFlags = "--mm:orc -d:chronicles_log_level=WARN"

task build, "Compile the echo library":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libecho echo.nim"

task genbindings_cpp, "Generate C++ bindings for the echo example":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libecho" &
    " -d:ffiGenBindings -d:targetLang=cpp" & " -d:ffiOutputDir=cpp_bindings" &
    " -d:ffiSrcPath=echo.nim" & " -o:/dev/null echo.nim"
