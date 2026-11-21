## Rejection fixture: two events of one library whose names share a name id fail
## the build. The clash is forged: a real FNV-1a 64 collision cannot be written down.

import results
import ffi
import ffi/codegen/meta

type ClashEvtLib = object

{.emit: "void libclashevtNimMain(void) {}".}

declareLibrary("clashevt", ClashEvtLib)

static:
  addNameIdClaim(
    FFINameIdClaim(
      id: nameId("on_second"), wireName: "on_first", kind: nkEvent, libName: "clashevt"
    )
  )

type Pinged {.ffi.} = object
  n: int

proc onSecond*(p: Pinged) {.ffiEvent.}
