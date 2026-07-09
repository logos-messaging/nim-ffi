## Compile fixture for the scalar-fast-path genBindings() behavior (see
## tests/unit/test_scalar_skip_gen.nim). Under `-d:ffiGenBindings` only the
## `c_abi` target has foreign-binding codegen for the scalar `abi = c` proc
## below; any other target must fail — unless `-d:ffiAllowScalarSkip` is
## passed, which downgrades the drop to a hint.

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
  ## All-scalar signature: dispatches through the CBOR-free fast path; only the
  ## `c_abi` target generates a foreign binding for it.
  return ok(lib.base + a + b)

genBindings()
