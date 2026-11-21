## Rejection fixture: two reverse calls of one library whose names share a name id
## fail the build (poll mode). The clash is forged, see name_id_clash_event_fixture.

import results
import ffi
import ffi/codegen/meta

type ClashRevLib = object

{.emit: "void libclashrevNimMain(void) {}".}

declareLibrary("clashrev", ClashRevLib)

static:
  addNameIdClaim(
    FFINameIdClaim(
      id: nameId("fetch"), wireName: "other", kind: nkReverseCall, libName: "clashrev"
    )
  )

proc fetch(): Future[Result[void, string]] {.ffiReverse.}
