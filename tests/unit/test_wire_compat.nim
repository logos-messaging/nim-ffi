## Wire-format compatibility tests.
##
## The C++ side now uses vendored TinyCBOR (see
## `ffi/codegen/templates/cpp/vendor/tinycbor/`) and the Nim side uses
## `cbor_serialization`. Both implement RFC 8949, but a regression on either
## side could silently produce divergent bytes for the same logical value.
##
## These tests pin the *exact* byte sequences `cbor_serialization` emits for
## a handful of representative shapes. If a future bump to the Nim library
## ever shifts the encoding (e.g., key ordering, integer length choice,
## optional/null handling), the assertions here will fail loudly before the
## C++ side gets to discover the divergence at runtime.
##
## The same golden bytes are exercised on the C++ side by the timer
## example's end-to-end round-trip (`examples/timer/cpp_bindings/main.cpp`).

import std/[options, strutils]
import unittest
import results
import ffi

type WireSimple {.ffi.} = object
  name: string

type WireWithInt {.ffi.} = object
  message: string
  delayMs: int

type WireWithOption {.ffi.} = object
  label: string
  note: Option[string]

type WireWithVector {.ffi.} = object
  items: seq[string]

proc toHex(bytes: openArray[byte]): string =
  var buf = ""
  for b in bytes:
    buf.add(b.toHex(2).toLowerAscii())
  return buf

suite "wire format — single-field map":
  test "WireSimple{name:\"abc\"} round-trips to a stable byte sequence":
    let v = WireSimple(name: "abc")
    let bytes = cborEncode(v)
    # map(1), key "name" (text-string len 4), value "abc" (text-string len 3)
    check toHex(bytes) == "a1646e616d6563616263"
    let back = cborDecode(bytes, WireSimple)
    check back.isOk
    check back.value.name == "abc"

suite "wire format — int field":
  test "WireWithInt encodes ints as CBOR integers":
    let v = WireWithInt(message: "hi", delayMs: 200)
    let bytes = cborEncode(v)
    # map(2), "message"->"hi", "delayMs"->200 (uint8 form: 0x18 0xc8)
    check toHex(bytes) == "a2676d65737361676562686967" & "64656c61794d7318c8"
    let back = cborDecode(bytes, WireWithInt)
    check back.isOk
    check back.value.message == "hi"
    check back.value.delayMs == 200

  test "negative int uses CBOR negative-integer major type":
    let v = WireWithInt(message: "x", delayMs: -1)
    let bytes = cborEncode(v)
    # 0x20 is CBOR -1
    check toHex(bytes).endsWith("20")

suite "wire format — Option[T]":
  ## Nim's `cbor_serialization/std/options` import encodes `Option[T]`:
  ##   - `some v` → emit the key and the inner value.
  ##   - `none T` → **omit the field entirely** from the map (the resulting
  ##                map is smaller by one entry).
  ##
  ## The C++ TinyCBOR helper currently encodes `std::nullopt` as CBOR null
  ## (0xf6). That divergence is invisible while no consumer sends
  ## `std::nullopt` over the wire (the timer example only sends `Some`
  ## values). If a future caller does, we'll need to align the conventions
  ## — either teach the C++ codec to skip None-valued keys (mirroring Nim),
  ## or switch the Nim side to emit explicit nulls. This test pins the
  ## current Nim behavior so the divergence is detectable instead of
  ## silent.

  test "Option.some encodes as the inner value (no wrapper)":
    let v = WireWithOption(label: "x", note: some("hi"))
    let bytes = cborEncode(v)
    # map(2): "label"->"x", "note"->"hi" (text strings, no null/tag wrapping)
    check toHex(bytes) == "a2656c6162656c6178646e6f7465626869"

  test "Option.none yields a smaller map without the optional key":
    let v = WireWithOption(label: "x", note: none(string))
    let bytes = cborEncode(v)
    # map(1): only "label"->"x"; the "note" key is absent.
    check toHex(bytes) == "a1656c6162656c6178"

suite "wire format — seq[T]":
  test "empty seq encodes as CBOR array(0)":
    let v = WireWithVector(items: @[])
    let bytes = cborEncode(v)
    # a1 (map 1) 65 (text-str len 5) 69 74 65 6d 73 ("items") 80 (array 0)
    check toHex(bytes) == "a1656974656d7380"

  test "three-element seq[string]":
    let v = WireWithVector(items: @["a", "bb", "ccc"])
    let bytes = cborEncode(v)
    # map(1), "items" -> array(3) of text strings "a", "bb", "ccc":
    # 83 (array 3) 61 61 ("a") 62 62 62 ("bb") 63 63 63 63 ("ccc")
    check toHex(bytes) == "a1656974656d7383616162626263636363"
