## Compile fixture for `{.ffiConst.}` binding generation (see
## tests/unit/test_ffi_const.nim): one const of every supported shape, including
## a computed value and a string needing escapes.

import ffi, chronos

type ConstLib = object
  base: int

declareLibrary("constlib", ConstLib)

const
  MaxPeers* {.ffiConst.} = 42
  DefaultTimeoutMs* {.ffiConst.}: uint32 = 3 * 1000
  Ratio* {.ffiConst.} = 1.5
  DebugEnabled* {.ffiConst.} = false
  Greeting* {.ffiConst.} = "he\"llo\n"
  HTTPPort* {.ffiConst.} = 8080

type ConstConfig {.ffi.} = object
  base: int

proc constlib_create*(cfg: ConstConfig): Future[Result[ConstLib, string]] {.ffiCtor.} =
  return ok(ConstLib(base: cfg.base))

proc constlib_base*(lib: ConstLib): Future[Result[int, string]] {.ffi.} =
  return ok(lib.base)

proc constlib_destroy*(lib: ConstLib) {.ffiDtor.} =
  discard

genBindings()
