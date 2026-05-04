import unittest
import results
import ../ffi/serial

ffiType:
  type Point = object
    x: int
    y: int

ffiType:
  type Nested = object
    label: string
    point: Point

suite "ffiSerialize / ffiDeserialize primitives":
  test "string round-trip":
    let s = "hello world"
    let serialized = ffiSerialize(s)
    let back = ffiDeserialize(serialized.cstring, string)
    check back.isOk()
    check back.value == s

  test "string with special chars":
    let s = "tab\there"
    let serialized = ffiSerialize(s)
    let back = ffiDeserialize(serialized.cstring, string)
    check back.isOk()
    check back.value == s

  test "int round-trip":
    let v = 42
    let serialized = ffiSerialize(v)
    let back = ffiDeserialize(serialized.cstring, int)
    check back.isOk()
    check back.value == v

  test "int negative round-trip":
    let v = -100
    let serialized = ffiSerialize(v)
    let back = ffiDeserialize(serialized.cstring, int)
    check back.isOk()
    check back.value == v

  test "bool true round-trip":
    let serialized = ffiSerialize(true)
    let back = ffiDeserialize(serialized.cstring, bool)
    check back.isOk()
    check back.value == true

  test "bool false round-trip":
    let serialized = ffiSerialize(false)
    let back = ffiDeserialize(serialized.cstring, bool)
    check back.isOk()
    check back.value == false

  test "float round-trip":
    let v = 3.14
    let serialized = ffiSerialize(v)
    let back = ffiDeserialize(serialized.cstring, float)
    check back.isOk()
    check abs(back.value - v) < 1e-9

  test "float negative round-trip":
    let v = -2.718
    let serialized = ffiSerialize(v)
    let back = ffiDeserialize(serialized.cstring, float)
    check back.isOk()
    check abs(back.value - v) < 1e-9

suite "pointer serialization":
  test "pointer serialize and recover address":
    var x = 12345
    let p = addr x
    let serialized = ffiSerialize(cast[pointer](p))
    let back = ffiDeserialize(serialized.cstring, pointer)
    check back.isOk()
    check back.value == cast[pointer](p)

  test "nil pointer serializes as 0":
    let p: pointer = nil
    let serialized = ffiSerialize(p)
    check serialized == "0"

suite "ffiType macro — object round-trip":
  test "Point round-trip":
    let pt = Point(x: 10, y: 20)
    let serialized = ffiSerialize(pt)
    let back = ffiDeserialize(serialized.cstring, Point)
    check back.isOk()
    check back.value.x == 10
    check back.value.y == 20

  test "Nested object round-trip":
    let n = Nested(label: "origin", point: Point(x: 0, y: 0))
    let serialized = ffiSerialize(n)
    let back = ffiDeserialize(serialized.cstring, Nested)
    check back.isOk()
    check back.value.label == "origin"
    check back.value.point.x == 0
    check back.value.point.y == 0

suite "ffiDeserialize error handling":
  test "malformed JSON returns err":
    let back = ffiDeserialize("not json at all".cstring, int)
    check back.isErr()

  test "wrong JSON type returns err for string":
    let back = ffiDeserialize("42".cstring, string)
    check back.isErr()

  test "malformed JSON for object returns err":
    let back = ffiDeserialize("{bad json".cstring, Point)
    check back.isErr()
