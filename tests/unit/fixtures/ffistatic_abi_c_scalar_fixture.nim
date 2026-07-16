## Must fail: `{.ffiStatic.}` never rides the ctx-bound all-scalar fast path, so a
## scalar return has no `abi = c` reply shape. The error must say so, not die on an
## undeclared `int_CWire` (see tests/unit/test_ffistatic_reject.nim).

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
