## Must fail: `{.ffiDtor.}` on a method shape (see tests/unit/test_ffi_router_reject.nim).

import ffi, chronos

type RouterRejLib = object
  base: int

declareLibrary("routerrej", RouterRejLib)

proc routerrejBad*(lib: RouterRejLib): Future[Result[int, string]] {.ffiDtor.} =
  return ok(lib.base)

genBindings()
