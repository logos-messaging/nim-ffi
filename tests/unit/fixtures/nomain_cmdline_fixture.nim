import std/os
import ffi

type CmdlineLib = ref object

declareLibrary("cmdlinefixture", CmdlineLib)

proc checkCommandLine(): cint {.exportc, cdecl.} =
  if paramCount() == 1 and paramStr(0) == "host" and paramStr(1) == "argument":
    1
  else:
    0

when not compileOption("noMain"):
  doAssert paramCount() >= 0
