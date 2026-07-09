version = "0.1.0"
packageName = "skeleton"
author = "Institute of Free Technology"
description = "Minimal nim-ffi library template — copy-rename to start a new lib"
license = "MIT or Apache License 2.0"

requires "nim >= 2.2.6"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "https://github.com/logos-messaging/nim-ffi >= 0.2.0"

const nimFlags = "--mm:orc -d:chronicles_log_level=WARN"

task build, "Compile the skeleton library":
  exec "nim c " & nimFlags &
    " --app:lib --noMain --nimMainPrefix:libskeleton skeleton.nim"

task genbindings_cpp, "Generate C++ bindings for the skeleton example":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libskeleton" &
    " -d:ffiGenBindings -d:targetLang=cpp" & " -d:ffiOutputDir=cpp_bindings" &
    " -d:ffiSrcPath=skeleton.nim" & " -o:/dev/null skeleton.nim"
