## Must fail: `{.ffiEvent.}` on a static shape (see tests/unit/test_ffi_router_reject.nim).

import ffi, chronos

type RouterRejLib = object
  base: int

declareLibrary("routerrej", RouterRejLib)

proc routerrejBad*(n: int): Future[Result[int, string]] {.ffiEvent.} =
  return ok(n)

genBindings()
