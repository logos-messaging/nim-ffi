## Rejection fixture: `timeout = 0` would fail every reverse call at once.

import results
import ffi

type RevZeroLib = object

{.emit: "void librevzeroNimMain(void) {}".}

declareLibrary("revzero", RevZeroLib)

proc askHost(): Future[Result[void, string]] {.ffiReverse(timeout = 0).}
