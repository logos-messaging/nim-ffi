## Acceptance fixture: a {.ffiReverse.} proc in a module other than the one
## calling declareLibrary, the layout of a real library. Its set_impl export
## must still pass its own `release` param, not chronos' `release` overloads.

import results
import ffi
import ./reverse_split_lib

proc askHost(): Future[Result[void, string]] {.ffiReverse.}
