## Compile fixture: a leftover `"abi = cbor"` on an `{.ffiEvent.}` must fail
## rather than become an event whose wire name is `abi = cbor`.

import results
import ffi

type EvtLib = object

{.emit: "void libabievtNimMain(void) {}".}

declareLibrary("abievt", EvtLib)

type Pinged {.ffi.} = object
  n: int

proc abievt_pinged*(p: Pinged) {.ffiEvent: "abi = cbor".}
