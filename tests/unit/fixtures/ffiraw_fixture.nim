## Compile fixture for the `{.ffiRaw.}` entry point (see
## tests/unit/test_ffi_raw.nim): nothing else in the tree uses that pragma, so
## its expansion would otherwise never be compiled.

import ffi, chronos

type RawLib = object

declareLibrary("rawlib", RawLib)

proc rawlib_echo*(
    ctx: ptr FFIContext[RawLib], callback: FFICallBack, userData: pointer, msg: string
): Future[Result[string, string]] {.ffiRaw.} =
  return ok(msg)

genBindings()
