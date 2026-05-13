import std/options
import unittest
import results
import ../ffi/cbor_serial

ffiType:
  type Point = object
    x: int
    y: int

ffiType:
  type Nested = object
    label: string
    point: Point

type Color = enum
  cRed, cGreen, cBlue

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

suite "CBOR pointer / ptr":
  test "pointer round-trip":
    var x = 12345
    let p = cast[pointer](addr x)
    let bytes = cborEncode(p)
    check cborDecode(bytes, pointer).value == p

  test "nil pointer":
    let p: pointer = nil
    let bytes = cborEncode(p)
    check cborDecode(bytes, pointer).value == nil

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
