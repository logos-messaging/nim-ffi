## Compile fixture for the scalar-fast-path drop error (see
## tests/unit/test_scalar_skip_gen.nim). This is a CBOR-default library with one
## stray scalar `abi = c` proc, so no target can emit a binding for it: under
## `-d:ffiGenBindings` genBindings() must fail — unless `-d:ffiAllowScalarSkip`
## is passed, which downgrades the drop to a hint.

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
  ## All-scalar signature: dispatches through the CBOR-free fast path. In this
  ## CBOR-default library no target can emit a foreign binding for it.
  return ok(lib.base + a + b)

genBindings()
