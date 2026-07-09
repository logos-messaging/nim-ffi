version = "0.1.0"
packageName = "timer"
author = "Institute of Free Technology"
description = "Example Nim timer library using nim-ffi"
license = "MIT or Apache License 2.0"

requires "nim >= 2.2.6"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "https://github.com/logos-messaging/nim-ffi >= 0.2.0"

const nimFlags = "--mm:orc -d:chronicles_log_level=WARN"

proc genBindingsCmd(langs: string): string =
  ## One `nim c` that emits `langs` (comma-separated) from timer.nim, each into
  ## `<lang>_bindings/`. `--compileOnly` is enough — the files are written during
  ## macro expansion, nothing is linked.
  "nim c " & nimFlags & " -d:ffiGenBindings -d:targetLang=" & langs &
    " --compileOnly timer.nim"

task build, "Compile the timer library":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libmy_timer timer.nim"

task genbindings, "Generate Rust, C++ and C bindings for the timer example":
  exec genBindingsCmd("rust,cpp,c")

task genbindings_rust, "Generate Rust bindings for the timer example":
  exec genBindingsCmd("rust")

task genbindings_cpp, "Generate C++ bindings for the timer example":
  exec genBindingsCmd("cpp")

task genbindings_c, "Generate C bindings for the timer example":
  exec genBindingsCmd("c")
