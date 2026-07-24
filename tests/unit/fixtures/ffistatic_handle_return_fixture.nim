## Must fail: `{.ffiStatic.}` handle return (see tests/unit/test_ffistatic_reject.nim).

import ffi, chronos

type StaticLib = object
  base: int

declareLibrary("staticrej", StaticLib)

type Session {.ffiHandle.} = ref object
  id: int

proc staticrejBad*(): Future[Result[Session, string]] {.ffiStatic.} =
  return ok(Session(id: 1))

genBindings()
