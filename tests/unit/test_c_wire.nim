## Round-trip correctness for the `c` (flat C-struct) ABI codec.
##
## Each `{.ffi: "abi = c".}` type gets a `<T>_CWire` companion plus
## `cwirePack` / `cwireUnpack` / `cwireFree`. This asserts
## `cwireUnpack(cwirePack(x)) == x` across the supported field shapes —
## scalars, strings, `seq`, `Option`, nested {.ffi.} structs, and nested
## composites like `seq[Option[T]]` — including the empty/none edge cases the
## cstring/pointer encoding must handle.
##
## `genBindings()` flushes the cwire companions for every abi=c type declared
## above it (a type-pragma macro can't splice them in at the type site).

import std/options
import unittest2
import ffi

type Inner {.ffi: "abi = c".} = object
  label: string
  weight: int

type Outer {.ffi: "abi = c".} = object
  name: string
  count: int
  flag: bool
  inner: Inner
  items: seq[Inner]
  tags: seq[string]
  note: Option[string]
  retries: Option[int]
  blob: seq[byte]
  maybeInner: Option[Inner]
  optItems: seq[Option[Inner]]
  optTags: seq[Option[string]]

genBindings()

proc roundTrip(o: Outer): Outer =
  ## Pack into the wire struct, copy back out, then release the wire
  ## allocations — the exact lifecycle a boundary crossing would use.
  var wire: Outer_CWire
  cwirePack(wire, o)
  let back = cwireUnpack(wire)
  cwireFree(wire)
  return back

suite "c-ABI cwire round-trip":
  test "fully-populated value survives pack/unpack/free":
    let o = Outer(
      name: "outer",
      count: 42,
      flag: true,
      inner: Inner(label: "core", weight: 7),
      items: @[Inner(label: "a", weight: 1), Inner(label: "b", weight: 2)],
      tags: @["x", "y", "z"],
      note: some("a note"),
      retries: some(3),
      blob: @[1'u8, 2, 3, 255],
      maybeInner: some(Inner(label: "opt", weight: 99)),
      optItems: @[some(Inner(label: "p", weight: 5)), none(Inner)],
      optTags: @[some("kept"), none(string), some("")],
    )
    check roundTrip(o) == o

  test "empty strings, empty seqs, and none Options survive":
    let o = Outer(
      name: "",
      count: 0,
      flag: false,
      inner: Inner(label: "", weight: 0),
      items: @[],
      tags: @[],
      note: none(string),
      retries: none(int),
      blob: @[],
      maybeInner: none(Inner),
      optItems: @[],
      optTags: @[],
    )
    let back = roundTrip(o)
    check back == o
    check back.note.isNone
    check back.retries.isNone
    check back.maybeInner.isNone
    check back.items.len == 0
    check back.blob.len == 0
    check back.optItems.len == 0

  test "nested seq elements keep their string fields":
    let o = Outer(
      name: "n",
      inner: Inner(label: "i", weight: 9),
      items: @[Inner(label: "alpha", weight: 10), Inner(label: "beta", weight: 20)],
      note: some(""), # some-of-empty-string must stay `some`, not collapse to none
    )
    let back = roundTrip(o)
    check back.items.len == 2
    check back.items[1].label == "beta"
    check back.note.isSome
    check back.note.get == ""

  test "seq[Option[T]] elements round-trip per-element some/none":
    let o = Outer(
      name: "rec",
      optItems: @[
        some(Inner(label: "x", weight: 1)),
        none(Inner),
        some(Inner(label: "z", weight: 3)),
      ],
      optTags: @[none(string), some("mid"), some("")],
    )
    let back = roundTrip(o)
    check back.optItems.len == 3
    check back.optItems[0].isSome
    check back.optItems[0].get.label == "x"
    check back.optItems[1].isNone
    check back.optItems[2].get.weight == 3
    check back.optTags[0].isNone
    check back.optTags[1].get == "mid"
    check back.optTags[2].isSome
    check back.optTags[2].get == ""
