## Compile fixture: a leftover `"abi = c"` argument on a `{.ffi.}` proc must
## fail the build, since the wire selector is gone.

import results
import ffi

type SpecLib = object

{.emit: "void libabispecNimMain(void) {}".}

declareLibrary("abispec", SpecLib)

proc abispec_ping*(lib: SpecLib): Future[Result[string, string]] {.ffi: "abi = c".} =
  return ok("pong")

proc abispec_destroy*(lib: SpecLib) {.ffiDtor.} =
  discard
