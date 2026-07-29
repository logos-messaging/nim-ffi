## Must fail: `{.ffiExport.}` on a static shape (see tests/unit/test_ffi_router_reject.nim).

import ffi, chronos

type RouterRejLib = object
  base: int

declareLibrary("routerrej", RouterRejLib)

proc routerrejBad*(): Future[Result[int, string]] {.ffiExport.} =
  return ok(1)

genBindings()
