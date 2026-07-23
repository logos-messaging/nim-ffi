## Must fail: no `abi = c` reply shape for a static's scalar return, and the error
## must say so rather than die on an undeclared `int_CWire`.

import ffi, chronos

type ScalarLib = object
  base: int

declareLibrary("staticscalar", ScalarLib, defaultABIFormat = "c")

type ScalarConfig {.ffi.} = object
  base: int

proc staticscalarCreate*(
    cfg: ScalarConfig
): Future[Result[ScalarLib, string]] {.ffiCtor.} =
  return ok(ScalarLib(base: cfg.base))

proc staticscalarAdd*(a: int, b: int): Future[Result[int, string]] {.ffiStatic.} =
  return ok(a + b)

genBindings()
