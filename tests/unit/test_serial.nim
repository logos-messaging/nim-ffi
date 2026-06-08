import std/[math, options]
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

type BytesHolder {.ffi.} = object
  blob: seq[byte]

type DeepInner {.ffi.} = object
  tag: string
  nested: Nested

type ComplexContainer {.ffi.} = object
  ids: seq[int]
  names: seq[string]
  points: seq[Point]
  maybePoint: Option[Point]
  maybeNames: Option[seq[string]]
  flags: seq[Option[int]]
  blob: seq[byte]

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

suite "CBOR boundaries":
  test "int8":
    for v in [low(int8), int8(-1), int8(0), int8(1), high(int8)]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, int8).value == v

  test "int16":
    for v in [low(int16), int16(-1), int16(0), int16(1), high(int16)]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, int16).value == v

  test "int32":
    for v in [low(int32), int32(-1), int32(0), int32(1), high(int32)]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, int32).value == v

  test "int64":
    for v in [low(int64), int64(-1), int64(0), int64(1), high(int64)]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, int64).value == v

  test "uint8":
    for v in [uint8(0), uint8(1), high(uint8)]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, uint8).value == v

  test "uint16":
    for v in [uint16(0), uint16(1), high(uint16)]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, uint16).value == v

  test "uint32":
    for v in [uint32(0), uint32(1), high(uint32)]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, uint32).value == v

  test "uint64 (UINT64_MAX)":
    for v in [uint64(0), uint64(1), high(uint64)]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, uint64).value == v

  test "float32 finite values incl. ±FLT_MAX":
    for v in [
      float32(0.0),
      float32(-0.0),
      float32(1.5),
      float32(-1.5),
      float32(3.4028235e38),
      float32(-3.4028235e38),
    ]:
      let bytes = cborEncode(v)
      check cborDecode(bytes, float32).value == v

  test "float64 NaN":
    let bytes = cborEncode(NaN)
    let back = cborDecode(bytes, float64)
    check back.isOk
    check back.value.classify == fcNan

  test "float32 NaN":
    let v: float32 = NaN
    let bytes = cborEncode(v)
    let back = cborDecode(bytes, float32)
    check back.isOk
    check back.value.classify == fcNan

  test "float64 +Inf and -Inf":
    let posBytes = cborEncode(Inf)
    check cborDecode(posBytes, float64).value == Inf
    let negBytes = cborEncode(NegInf)
    check cborDecode(negBytes, float64).value == NegInf

  test "float32 +Inf and -Inf":
    let pos: float32 = Inf
    let neg: float32 = NegInf
    check cborDecode(cborEncode(pos), float32).value == pos
    check cborDecode(cborEncode(neg), float32).value == neg

  test "float64 subnormal":
    # 5e-324 is the smallest positive float64 subnormal (Double.MIN_VALUE).
    let v = 5e-324
    let bytes = cborEncode(v)
    let back = cborDecode(bytes, float64)
    check back.isOk
    check back.value == v
    check back.value.classify == math.fcSubnormal

  test "float32 subnormal (compared by bit pattern)":
    # The smallest positive float32 subnormal has bit pattern 0x00000001.
    # `math.classify` widens to float64 and would re-classify this as normal,
    # so we compare the raw 32-bit bit pattern instead.
    let v = cast[float32](0x00000001'u32)
    let bytes = cborEncode(v)
    let back = cborDecode(bytes, float32)
    check back.isOk
    check cast[uint32](back.value) == 0x00000001'u32

suite "CBOR round-trips":
  test "seq[byte]":
    let bs: seq[byte] = @[0x00'u8, 0x01'u8, 0x7f'u8, 0x80'u8, 0xff'u8]
    let bytes = cborEncode(bs)
    check cborDecode(bytes, seq[byte]).value == bs

  test "empty seq[byte] encodes as CBOR bytes(0)":
    let bs: seq[byte] = @[]
    let bytes = cborEncode(bs)
    # 0x40 = major type 2 (bytes), length 0.
    check bytes.len == 1
    check bytes[0] == 0x40'u8
    check cborDecode(bytes, seq[byte]).value == bs

  test "seq[byte] with embedded NUL bytes":
    let bs: seq[byte] = @[0x00'u8, 0xde'u8, 0x00'u8, 0xad'u8, 0x00'u8]
    let bytes = cborEncode(bs)
    let back = cborDecode(bytes, seq[byte])
    check back.isOk
    check back.value == bs
    check back.value.len == 5

  test "string with embedded NUL keeps length, not C-string termination":
    let s = "a\0b\0c"
    check s.len == 5
    let bytes = cborEncode(s)
    let back = cborDecode(bytes, string)
    check back.isOk
    check back.value.len == 5
    check back.value == s

  test "object with seq[byte] field":
    let h = BytesHolder(blob: @[0x00'u8, 0xff'u8, 0x10'u8, 0x00'u8])
    let bytes = cborEncode(h)
    let back = cborDecode(bytes, BytesHolder)
    check back.isOk
    check back.value.blob == h.blob

  test "seq[Option[int]] mixes some and none":
    let s = @[some(1), none(int), some(-3), none(int), some(0)]
    let bytes = cborEncode(s)
    let back = cborDecode(bytes, seq[Option[int]])
    check back.isOk
    check back.value == s

  test "Option[seq[int]] some":
    let o = some(@[1, 2, 3])
    let bytes = cborEncode(o)
    let back = cborDecode(bytes, Option[seq[int]])
    check back.isOk
    check back.value == o

  test "Option[seq[int]] none":
    let o = none(seq[int])
    let bytes = cborEncode(o)
    let back = cborDecode(bytes, Option[seq[int]])
    check back.isOk
    check back.value == o

  test "three-level struct nesting":
    let d =
      DeepInner(tag: "outer", nested: Nested(label: "mid", point: Point(x: 11, y: 22)))
    let bytes = cborEncode(d)
    let back = cborDecode(bytes, DeepInner)
    check back.isOk
    check back.value.tag == "outer"
    check back.value.nested.label == "mid"
    check back.value.nested.point.x == 11
    check back.value.nested.point.y == 22

  test "seq[Nested] preserves element order and content":
    let s = @[
      Nested(label: "a", point: Point(x: 1, y: 2)),
      Nested(label: "b", point: Point(x: 3, y: 4)),
      Nested(label: "c", point: Point(x: 5, y: 6)),
    ]
    let bytes = cborEncode(s)
    let back = cborDecode(bytes, seq[Nested])
    check back.isOk
    check back.value.len == 3
    check back.value[1].label == "b"
    check back.value[2].point.y == 6

  test "Option[Nested] some/none":
    let some1 = some(Nested(label: "x", point: Point(x: 7, y: 8)))
    let back1 = cborDecode(cborEncode(some1), Option[Nested])
    check back1.isOk
    check back1.value.isSome
    check back1.value.get.label == "x"

    let none1 = none(Nested)
    let back2 = cborDecode(cborEncode(none1), Option[Nested])
    check back2.isOk
    check back2.value.isNone

  test "ComplexContainer with mixed nested fields":
    let c = ComplexContainer(
      ids: @[1, 2, 3],
      names: @["alpha", "beta"],
      points: @[Point(x: 1, y: 2), Point(x: 3, y: 4)],
      maybePoint: some(Point(x: 9, y: 9)),
      maybeNames: some(@["a", "b"]),
      flags: @[some(1), none(int), some(2)],
      blob: @[0x00'u8, 0xff'u8, 0x42'u8],
    )
    let bytes = cborEncode(c)
    let back = cborDecode(bytes, ComplexContainer)
    check back.isOk
    check back.value.ids == c.ids
    check back.value.names == c.names
    check back.value.points.len == 2
    check back.value.points[1].y == 4
    check back.value.maybePoint.isSome
    check back.value.maybePoint.get.x == 9
    check back.value.maybeNames == c.maybeNames
    check back.value.flags == c.flags
    check back.value.blob == c.blob

  test "ComplexContainer with all-empty / all-none fields":
    let c = ComplexContainer(
      ids: @[],
      names: @[],
      points: @[],
      maybePoint: none(Point),
      maybeNames: none(seq[string]),
      flags: @[],
      blob: @[],
    )
    let bytes = cborEncode(c)
    let back = cborDecode(bytes, ComplexContainer)
    check back.isOk
    check back.value.ids.len == 0
    check back.value.names.len == 0
    check back.value.points.len == 0
    check back.value.maybePoint.isNone
    check back.value.maybeNames.isNone
    check back.value.flags.len == 0
    check back.value.blob.len == 0

  # Sizes chosen to cross the 24/256/65536-byte CBOR length-encoding
  # boundaries and the encoder's internal buffer-grow thresholds.

  test "string >64 KiB":
    const n = 70_000
    var big = newString(n)
    for i in 0 ..< n:
      big[i] = char(ord('a') + (i mod 26))
    let bytes = cborEncode(big)
    let back = cborDecode(bytes, string)
    check back.isOk
    check back.value.len == n
    check back.value == big

  test "seq[byte] >64 KiB with embedded NULs":
    const n = 70_000
    var blob = newSeq[byte](n)
    for i in 0 ..< n:
      blob[i] = byte(i mod 256)
    let bytes = cborEncode(blob)
    let back = cborDecode(bytes, seq[byte])
    check back.isOk
    check back.value.len == n
    check back.value == blob

  test "string >1 MiB":
    const n = 1_200_000
    var big = newString(n)
    for i in 0 ..< n:
      big[i] = char(ord('a') + (i mod 26))
    let bytes = cborEncode(big)
    let back = cborDecode(bytes, string)
    check back.isOk
    check back.value.len == n
    check back.value[0] == big[0]
    check back.value[n - 1] == big[n - 1]
    check back.value == big

  test "seq[byte] >1 MiB":
    const n = 1_200_000
    var blob = newSeq[byte](n)
    for i in 0 ..< n:
      blob[i] = byte(i mod 256)
    let bytes = cborEncode(blob)
    let back = cborDecode(bytes, seq[byte])
    check back.isOk
    check back.value.len == n
    check back.value == blob

  test "seq[Point] with 100k elements":
    const n = 100_000
    var pts = newSeq[Point](n)
    for i in 0 ..< n:
      pts[i] = Point(x: i, y: -i)
    let bytes = cborEncode(pts)
    let back = cborDecode(bytes, seq[Point])
    check back.isOk
    check back.value.len == n
    check back.value[0].x == 0
    check back.value[n - 1].x == n - 1
    check back.value[n - 1].y == -(n - 1)

suite "CBOR void / null sentinel":
  ## `CborNullByte` is the wire sentinel used by `ffi_thread_request` to
  ## carry a "successful but no value" reply (an `.ffi.` proc whose handler
  ## returns `Result[void, string]`). See `ffi/cbor_serial.nim` and
  ## `ffi/ffi_thread_request.nim` for the producer side.

  test "CborNullByte equals CBOR null (0xf6)":
    check CborNullByte == 0xf6'u8

  test "top-level none(T) encodes as the single sentinel byte":
    let bytes = cborEncode(none(int))
    check bytes.len == 1
    check bytes[0] == CborNullByte

  test "decoding the sentinel byte as Option[T] yields none":
    let bytes = @[CborNullByte]
    let back = cborDecode(bytes, Option[int])
    check back.isOk
    check back.value.isNone

  test "decoding the sentinel as a required object type errors out":
    # A consumer that expects a real payload but is handed the void sentinel
    # must fail explicitly rather than silently materializing a zeroed value.
    let bytes = @[CborNullByte]
    let back = cborDecode(bytes, Point)
    check back.isErr
