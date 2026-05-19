import std/options
import unittest
import results
import ffi

type Point {.ffi.} = object
  x: int
  y: int

type Nested {.ffi.} = object
  label: string
  point: Point

type RefBox {.ffi.} = object
  label: string
  n: int

type Color = enum
  cRed
  cGreen
  cBlue

suite "CBOR primitives round-trip":
  test "bool true":
    let bytes = cborEncode(true)
    check cborDecode(bytes, bool).value == true

  test "bool false":
    let bytes = cborEncode(false)
    check cborDecode(bytes, bool).value == false

  test "int positive":
    let v = 42
    let bytes = cborEncode(v)
    check cborDecode(bytes, int).value == v

  test "int negative":
    let v = -100
    let bytes = cborEncode(v)
    check cborDecode(bytes, int).value == v

  test "int64 large":
    let v: int64 = 1_000_000_000_000
    let bytes = cborEncode(v)
    check cborDecode(bytes, int64).value == v

  test "int32 round-trip":
    let v: int32 = -32_000
    let bytes = cborEncode(v)
    check cborDecode(bytes, int32).value == v

  test "uint round-trip":
    let v: uint64 = 0xdeadbeef'u64
    let bytes = cborEncode(v)
    check cborDecode(bytes, uint64).value == v

  test "float64 round-trip":
    let v = 3.141592653589793
    let bytes = cborEncode(v)
    check abs(cborDecode(bytes, float64).value - v) < 1e-12

  test "float64 negative":
    let v = -2.718281828
    let bytes = cborEncode(v)
    check abs(cborDecode(bytes, float64).value - v) < 1e-9

  test "string round-trip":
    let s = "hello world"
    let bytes = cborEncode(s)
    check cborDecode(bytes, string).value == s

  test "empty string":
    let s = ""
    let bytes = cborEncode(s)
    check cborDecode(bytes, string).value == s

  test "string with special chars":
    let s = "tab\there\nnewline"
    let bytes = cborEncode(s)
    check cborDecode(bytes, string).value == s

suite "CBOR object":
  test "Point round-trip":
    let pt = Point(x: 10, y: -20)
    let bytes = cborEncode(pt)
    let back = cborDecode(bytes, Point)
    check back.isOk
    check back.value.x == 10
    check back.value.y == -20

  test "Nested object round-trip":
    let n = Nested(label: "origin", point: Point(x: 1, y: 2))
    let bytes = cborEncode(n)
    let back = cborDecode(bytes, Nested)
    check back.isOk
    check back.value.label == "origin"
    check back.value.point.x == 1
    check back.value.point.y == 2

suite "CBOR ref T (value-copy contract)":
  ## cbor_serialization's default `ref T` writer dereferences and encodes the
  ## pointee. On decode the receiving side allocates a fresh `ref` local to
  ## its own GC heap — no address crosses the boundary and the two refs are
  ## independent. Documented in ffi/cbor_serial.nim's module header.

  test "ref RefBox round-trip produces an independent ref":
    let original = (ref RefBox)(label: "hi", n: 7)
    let bytes = cborEncode(original)
    let back = cborDecode(bytes, ref RefBox)
    check back.isOk
    check back.value != nil
    check back.value.label == "hi"
    check back.value.n == 7
    # Mutate the decoded copy; the original must be untouched (proving no
    # aliasing). If the wire format ever switched to identity-preserving
    # transport, this would fail.
    back.value.label = "mutated"
    check original.label == "hi"
    check cast[pointer](back.value) != cast[pointer](original)

  test "nil ref round-trips as nil":
    let original: ref RefBox = nil
    let bytes = cborEncode(original)
    let back = cborDecode(bytes, ref RefBox)
    check back.isOk
    check back.value == nil

suite "CBOR seq / array":
  test "seq[int] round-trip":
    let s = @[1, 2, 3, -4, 5]
    let bytes = cborEncode(s)
    check cborDecode(bytes, seq[int]).value == s

  test "empty seq":
    let s: seq[int] = @[]
    let bytes = cborEncode(s)
    check cborDecode(bytes, seq[int]).value == s

  test "seq[string]":
    let s = @["a", "bb", "ccc"]
    let bytes = cborEncode(s)
    check cborDecode(bytes, seq[string]).value == s

  test "seq[Point]":
    let s = @[Point(x: 1, y: 2), Point(x: 3, y: 4)]
    let bytes = cborEncode(s)
    let back = cborDecode(bytes, seq[Point]).value
    check back.len == 2
    check back[0].x == 1
    check back[1].y == 4

suite "CBOR Option":
  test "some int":
    let o = some(42)
    let bytes = cborEncode(o)
    check cborDecode(bytes, Option[int]).value == o

  test "none int":
    let o = none(int)
    let bytes = cborEncode(o)
    check cborDecode(bytes, Option[int]).value == o

  test "some object":
    let o = some(Point(x: 7, y: 8))
    let bytes = cborEncode(o)
    let back = cborDecode(bytes, Option[Point]).value
    check back.isSome
    check back.get.x == 7

suite "CBOR enum":
  test "enum round-trip":
    let c = cGreen
    let bytes = cborEncode(c)
    check cborDecode(bytes, Color).value == c

suite "CBOR error handling":
  test "garbage input returns err":
    let garbage = @[0xff'u8, 0xff'u8]
    let res = cborDecode(garbage, int)
    check res.isErr

  test "truncated input returns err":
    let bytes = cborEncode("hello")
    let truncated = bytes[0 ..< 2]
    let res = cborDecode(truncated, string)
    check res.isErr

# ---------------------------------------------------------------------------
# Regression for PR #23 review item 9: cborEncodeShared writes directly into
# a c_malloc buffer, letting the FFI thread request take ownership without
# an intermediate seq[byte] copy. The shared-encoder must produce
# byte-for-byte the same output as the seq-encoder.
# ---------------------------------------------------------------------------

import system/ansi_c

suite "cborEncodeShared":
  test "object payload round-trips":
    let n = Nested(label: "", point: Point(x: 0, y: 0))
    let (sd, sl) = cborEncodeShared(n)
    defer:
      if not sd.isNil:
        c_free(sd)
    check sl > 0
    let back = cborDecodePtr(sd, sl, Nested).value
    check back.label == ""
    check back.point.x == 0
    check back.point.y == 0

  test "shared encoder is byte-for-byte equal to seq encoder":
    let n = Nested(label: "hello", point: Point(x: 3, y: 4))
    let seqBytes = cborEncode(n)
    let (sd, sl) = cborEncodeShared(n)
    defer:
      if not sd.isNil:
        c_free(sd)
    check sl == seqBytes.len
    for i in 0 ..< sl:
      check sd[i] == seqBytes[i]
    let back = cborDecodePtr(sd, sl, Nested).value
    check back.label == "hello"
    check back.point.x == 3
    check back.point.y == 4

  test "large string growth":
    # Larger than the initial 16-byte cap so the encoder must grow several
    # times; verifies the shared-mode grower handles repeated reallocations.
    var big = newString(4096)
    for i in 0 ..< big.len:
      big[i] = char(ord('a') + (i mod 26))
    let (sd, sl) = cborEncodeShared(big)
    defer:
      if not sd.isNil:
        c_free(sd)
    let back = cborDecodePtr(sd, sl, string).value
    check back == big

  test "empty-string payload is the single byte 0x60 in shared mode":
    let (sd, sl) = cborEncodeShared("")
    defer:
      if not sd.isNil:
        c_free(sd)
    check sl == 1
    check sd[0] == 0x60'u8
