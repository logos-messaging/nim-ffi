## Must fail: a library declares an {.ffiCtor.} but no {.ffiDtor.}, so genBindings
## rejects it (issue #3) rather than leaving the context with no way to release.

import ffi, chronos

type NoDtorLib = object
  n: int

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libnodtorNimMain(void) {}".}

declareLibrary("nodtor", NoDtorLib)

type NoDtorCfg {.ffi.} = object
  n: int

proc nodtor_create*(c: NoDtorCfg): Future[Result[NoDtorLib, string]] {.ffiCtor.} =
  return ok(NoDtorLib(n: c.n))

genBindings()
