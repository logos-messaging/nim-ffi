## Round-trip correctness for the `c` (flat C-struct) ABI codec — flat path.
##
## Each `{.ffi: "abi = c".}` type gets a `<T>_CWire` companion plus
## `cwirePack` / `cwireUnpack` / `cwireFree`. This asserts
## `cwireUnpack(cwirePack(x)) == x` for the flat scalar+string field shapes,
## including the empty-string edge case the cstring encoding must handle.
##
## `genBindings()` flushes the cwire companions for every abi=c type declared
## above it (a type-pragma macro can't splice them in at the type site).

import unittest2
import ffi

type Flat {.ffi: "abi = c".} = object
  name: string
  label: string
  count: int
  size: uint32
  ratio: float64
  flag: bool

genBindings()

proc roundTrip(o: Flat): Flat =
  ## Pack into the flat wire struct, copy back out, then release the wire
  ## allocations — the exact lifecycle a boundary crossing would use.
  var wire: Flat_CWire
  cwirePack(wire, o)
  let back = cwireUnpack(wire)
  cwireFree(wire)
  return back

suite "c-ABI cwire round-trip (flat)":
  test "populated scalars and strings survive pack/unpack/free":
    let o = Flat(
      name: "hello",
      label: "world",
      count: -42,
      size: 4_000_000_000'u32,
      ratio: 3.5,
      flag: true,
    )
    let back = roundTrip(o)
    check back == o
    # Distinct strings must not alias one another.
    check back.name == "hello"
    check back.label == "world"

  test "empty strings survive pack/unpack/free":
    let o = Flat(name: "", label: "", count: 0, size: 0, ratio: 0.0, flag: false)
    let back = roundTrip(o)
    check back == o
    check back.name == ""
    check back.label == ""
