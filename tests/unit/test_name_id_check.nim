## A polled message names its event or reverse call by `nameId` alone, so two
## names of one library must never share an id: the build stops instead.

import std/macros
import unittest2
import ffi/ffi_msg
import ffi/codegen/meta

func claim(
    id: uint64, wireName: string, kind = "event", lib = "mylib"
): FFINameIdClaim =
  return FFINameIdClaim(id: id, wireName: wireName, kind: kind, libName: lib)

# A real FNV-1a 64 collision cannot be written down, so the clash is forged: the
# registry already holds another name under the id "on_second" hashes to.
static:
  ffiNameIdRegistry.add(
    FFINameIdClaim(
      id: nameId("on_second"),
      wireName: "on_first",
      kind: "event",
      libName: currentLibName,
    )
  )

macro claimEvent(wireName: static string) =
  ## What `{.ffiEvent.}` does with the name it is given.
  claimNameId(wireName, "event")

suite "name ids are unique within a library":
  test "another name under the same id is a clash":
    let held = [claim(7'u64, "on_first")]
    check held.clashingName(claim(7'u64, "on_second")) == "on_first"

  test "the same name again is not":
    let held = [claim(7'u64, "on_first")]
    check held.clashingName(claim(7'u64, "on_first")) == ""

  test "events and reverse calls are matched within their own kind":
    let held = [claim(7'u64, "on_first", kind = "event")]
    check held.clashingName(claim(7'u64, "fetch", kind = "reverse call")) == ""

  test "two libraries do not clash with each other":
    let held = [claim(7'u64, "on_first", lib = "one")]
    check held.clashingName(claim(7'u64, "on_second", lib = "two")) == ""

  test "a clash stops the build":
    check not compiles(claimEvent("on_second"))

  test "a name with an id of its own is accepted":
    check compiles(claimEvent("on_third"))
