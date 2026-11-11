## Rejection fixture: two reverse procs of one library cannot share a wire name;
## both would export `<lib>_set_<wire>_impl`.

import results
import ffi

type RevDupLib = object

{.emit: "void librevdupNimMain(void) {}".}

declareLibrary("revdup", RevDupLib)

proc askHost(): Future[Result[void, string]] {.ffiReverse("ask").}
proc askHostAgain(): Future[Result[void, string]] {.ffiReverse("ask").}
