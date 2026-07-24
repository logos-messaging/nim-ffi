## Must compile: the same shapes, with no handle crossing a static's boundary.

import ffi, chronos

type StaticLib = object
  base: int

declareLibrary("staticrej", StaticLib)

type Session {.ffiHandle.} = ref object
  id: int

proc staticrejFine*(n: int): Future[Result[int, string]] {.ffiStatic.} =
  return ok(n + 1)

proc staticrejOpen*(lib: StaticLib): Future[Result[Session, string]] {.ffi.} =
  ## A handle is fine on a method: it lives in the caller's own context.
  return ok(Session(id: lib.base))

genBindings()
