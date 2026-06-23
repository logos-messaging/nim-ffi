## Round-trip correctness for the `c` (flat C-struct) ABI codec.
##
## Each `{.ffi: "abi = c".}` type gets a `<T>_CWire` companion plus
## `cwirePack` / `cwireUnpack` / `cwireFree`. This asserts
## `cwireUnpack(cwirePack(x)) == x` across the supported field shapes —
## scalars, strings, `seq`, `Option`, `array`, named `tuple`, nested {.ffi.}
## structs, and nested composites (`seq[Option[T]]`, `array[N, tuple[...]]`,
## `Option[array[...]]`, ...) — including the empty/none/empty-string edge
## cases the cstring/pointer encoding must handle.
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

type Shapes {.ffi: "abi = c".} = object
  ## Exercises array/tuple wire shapes and their cross-nestings (array of
  ## array, tuple in array, array in Option, tuple in seq) alongside GC'd and
  ## nested-{.ffi.} element types.
  coords: array[3, int]
  labels: array[2, string]
  cells: array[2, Inner]
  matrix: array[2, array[2, int]]
  point: tuple[x: int, y: int]
  tagged: tuple[label: string, kv: Inner]
  grid: array[2, tuple[a: string, b: int]]
  optBox: Option[array[2, string]]
  pairs: seq[tuple[name: string, n: int]]

genBindings()

proc roundTrip(o: Outer): Outer =
  ## Pack into the wire struct, copy back out, then release the wire
  ## allocations — the exact lifecycle a boundary crossing would use.
  var wire: Outer_CWire
  cwirePack(wire, o)
  let back = cwireUnpack(wire)
  cwireFree(wire)
  return back

proc roundTrip(o: Shapes): Shapes =
  ## Same pack/unpack/free lifecycle as the `Outer` overload, for the
  ## array/tuple shapes.
  var wire: Shapes_CWire
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

suite "c-ABI cwire array/tuple round-trip":
  test "fully-populated array & tuple fields survive pack/unpack/free":
    let o = Shapes(
      coords: [1, 2, 3],
      labels: ["alpha", "beta"],
      cells: [Inner(label: "a", weight: 1), Inner(label: "b", weight: 2)],
      matrix: [[1, 2], [3, 4]],
      point: (x: 10, y: 20),
      tagged: (label: "lbl", kv: Inner(label: "k", weight: 9)),
      grid: [(a: "g0", b: 0), (a: "g1", b: 1)],
      optBox: some(["p", "q"]),
      pairs: @[(name: "n0", n: 0), (name: "n1", n: 1)],
    )
    check roundTrip(o) == o

  test "empty seq, none Option, and empty-string elements survive":
    let o = Shapes(
      coords: [0, 0, 0],
      labels: ["", ""],
      cells: [Inner(label: "", weight: 0), Inner(label: "", weight: 0)],
      matrix: [[0, 0], [0, 0]],
      point: (x: 0, y: 0),
      tagged: (label: "", kv: Inner(label: "", weight: 0)),
      grid: [(a: "", b: 0), (a: "", b: 0)],
      optBox: none(array[2, string]),
      pairs: @[],
    )
    let back = roundTrip(o)
    check back == o
    check back.optBox.isNone
    check back.pairs.len == 0

  test "GC'd contents inside array/tuple keep their values":
    let o = Shapes(
      labels: ["kept", "also kept"],
      cells: [Inner(label: "x", weight: 5), Inner(label: "y", weight: 6)],
      tagged: (label: "tag", kv: Inner(label: "deep", weight: 7)),
      grid: [(a: "first", b: 1), (a: "second", b: 2)],
      optBox: some(["box0", ""]),
      pairs: @[(name: "alpha", n: 10), (name: "", n: 20)],
    )
    let back = roundTrip(o)
    check back.labels[1] == "also kept"
    check back.cells[0].label == "x"
    check back.tagged.kv.label == "deep"
    check back.grid[1].a == "second"
    check back.optBox.get[0] == "box0"
    check back.optBox.get[1] == ""
    check back.pairs[1].name == ""
    check back.pairs[0].n == 10
