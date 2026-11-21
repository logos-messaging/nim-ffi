## Rejection fixture: an event dispatched by a literal name is claimed too, declared
## or not. The clash is forged, see name_id_clash_event_fixture.

import ffi
import ffi/codegen/meta

static:
  addNameIdClaim(
    FFINameIdClaim(
      id: nameId("on_second"), wireName: "on_first", kind: nkEvent, libName: ""
    )
  )

proc emitIt() {.gcsafe, raises: [].} =
  dispatchFFIEvent("on_second"):
    "x"
