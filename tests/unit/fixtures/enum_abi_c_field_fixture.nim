## Compile fixture: a CBOR enum reached from an `abi = c` type has no `_CWire`
## form, so the cwire builder must reject it (see tests/unit/test_ffi_enum.nim).

import ffi, chronos

type AbiFieldLib = object
  n: int

declareLibrary("abifieldlib", AbiFieldLib)

type Color {.ffi.} = enum
  cRed
  cGreen

type Wrapper {.ffi: "abi = c".} = object
  color: Color

genBindings()
