## Compile fixture: an enum in an `abi = c` library must be rejected, not
## silently mis-wired (see tests/unit/test_ffi_enum.nim).

import ffi, chronos

type AbiEnumLib = object
  n: int

declareLibrary("abienumlib", AbiEnumLib, "c")

type Color {.ffi.} = enum
  cRed
  cGreen

genBindings()
