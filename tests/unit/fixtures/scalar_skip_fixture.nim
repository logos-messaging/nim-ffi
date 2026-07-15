## Compile fixture for the scalar-fast-path drop error (see
## tests/unit/test_scalar_skip_gen.nim): the scalar `abi = c` proc has no
## foreign-binding codegen, so genBindings() fails unless -d:ffiAllowScalarSkip.

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
  ## All-scalar signature: CBOR-free fast path, no foreign-binding codegen yet.
  return ok(lib.base + a + b)

genBindings()
