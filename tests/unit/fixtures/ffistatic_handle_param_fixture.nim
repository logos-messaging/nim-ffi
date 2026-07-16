## Must fail: `{.ffiStatic.}` handle param (see tests/unit/test_ffistatic_reject.nim).

import ffi, chronos

type StaticLib = object
  base: int

declareLibrary("staticrej", StaticLib)

type Session {.ffiHandle.} = ref object
  id: int

proc staticrejBad*(s: Session): Future[Result[int, string]] {.ffiStatic.} =
  return ok(s.id)

genBindings()
