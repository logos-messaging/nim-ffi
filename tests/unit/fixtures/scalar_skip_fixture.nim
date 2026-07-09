## Compile fixture for the scalar-fast-path drop error (see
## tests/unit/test_scalar_skip_gen.nim). Under `-d:ffiGenBindings` the scalar
## `abi = c` proc below has no foreign-binding codegen, so genBindings() must
## fail — unless `-d:ffiAllowScalarSkip` is passed, which downgrades it to a hint.

import ffi, chronos

type SkipLib = object
  base: int

declareLibrary("scalarskip", SkipLib)

type SkipConfig {.ffi.} = object
  base: int

proc scalarskip_create*(cfg: SkipConfig): Future[Result[SkipLib, string]] {.ffiCtor.} =
  return ok(SkipLib(base: cfg.base))

proc scalarskip_add*(
    lib: SkipLib, a: int, b: int
): Future[Result[int, string]] {.ffi: "abi = c".} =
  ## All-scalar signature: dispatches through the CBOR-free fast path and has no
  ## foreign-binding codegen yet.
  return ok(lib.base + a + b)

genBindings()
