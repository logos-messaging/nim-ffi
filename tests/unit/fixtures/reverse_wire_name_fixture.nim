## Rejection fixture: the wire name is part of `<lib>_set_<wire>_impl`, so it must be a C identifier.

import results
import ffi

type RevWireLib = object

{.emit: "void librevwireNimMain(void) {}".}

declareLibrary("revwire", RevWireLib)

proc askHost(): Future[Result[void, string]] {.ffiReverse("ask-host").}
