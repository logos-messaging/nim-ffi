## Rejection fixture: the stale 0.3 `"abi = cbor"` must fail the build, not become a wire name.

import results
import ffi

type EvtLib = object

{.emit: "void libabievtNimMain(void) {}".}

declareLibrary("abievt", EvtLib)

type Pinged {.ffi.} = object
  n: int

proc abievt_pinged*(p: Pinged) {.ffiEvent: "abi = cbor".}
