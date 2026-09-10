version = "0.1.0"
packageName = "timer"
author = "Institute of Free Technology"
description = "Example Nim timer library using nim-ffi"
license = "MIT or Apache License 2.0"

requires "nim >= 2.2.6"
requires "chronos"
requires "chronicles"
requires "https://github.com/logos-messaging/nim-ffi >= 0.3.0"

const nimFlags = "--mm:orc -d:chronicles_log_level=WARN"

task build, "Compile the timer library":
  exec "nim c " & nimFlags & " --app:lib --noMain --nimMainPrefix:libmy_timer timer.nim"
