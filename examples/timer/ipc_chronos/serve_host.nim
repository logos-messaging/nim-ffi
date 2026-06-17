## Cross-platform host for the in-library CBOR server.
##
## The library *is* the server: `my_timer_serve` (compiled into libmy_timer with
## -d:ffiIpcServe) runs the chronos socket loop and dispatches each decoded
## request to the library's own procs directly. This host just links the lib and
## starts it. Written in Nim so the dylib link is handled portably (the C host
## `serve_host.c` is the POSIX-only equivalent).
##
##   serve_host tcp:0.0.0.0:9099       # any platform
##   serve_host unix:/tmp/timer.sock   # POSIX
import std/os

proc my_timer_serve(address: cstring): cint {.importc, cdecl.}

when isMainModule:
  if paramCount() != 1:
    stderr.writeLine "usage: serve_host <tcp:host:port | unix:path>"
    quit(2)
  quit(int(my_timer_serve(cstring(paramStr(1)))))
