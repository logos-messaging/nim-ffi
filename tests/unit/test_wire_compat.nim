## Pins the exact CBOR bytes Nim emits so it can't silently diverge from C++ TinyCBOR.

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

type WireWithBytes {.ffi.} = object
  blob: seq[byte]

type WireBytesEntry {.ffi.} = object
  ## A struct with a `seq[byte]` field. The type below uses it as a seq element.
  id: string
  data: seq[byte]

type WireNestedBytes {.ffi.} = object
  ## A `seq[byte]` in a struct that is a `seq` element. This shape broke the
  ## Rust backend, which wrote an integer array in place of a ByteBuf.
  entries: seq[WireBytesEntry]

proc toHex(bytes: openArray[byte]): string =
  var buf = ""
  for b in bytes:
    buf.add(b.toHex(2).toLowerAscii())
  return buf

suite "wire format — single-field map":
  test "WireSimple{name:\"abc\"} round-trips to a stable byte sequence":
    let v = WireSimple(name: "abc")
    let bytes = cborEncode(v)
    check toHex(bytes) == "a1646e616d6563616263"
    let back = cborDecode(bytes, WireSimple)
    check back.isOk
    check back.value.name == "abc"

suite "wire format — int field":
  test "WireWithInt encodes ints as CBOR integers":
    let v = WireWithInt(message: "hi", delayMs: 200)
    let bytes = cborEncode(v)
    check toHex(bytes) == "a2676d65737361676562686967" & "64656c61794d7318c8"
    let back = cborDecode(bytes, WireWithInt)
    check back.isOk
    check back.value.message == "hi"
    check back.value.delayMs == 200

  test "negative int uses CBOR negative-integer major type":
    let v = WireWithInt(message: "x", delayMs: -1)
    let bytes = cborEncode(v)
    check toHex(bytes).endsWith("20")

suite "wire format — Option[T]":
  ## Nim emits `some v` as key+value and omits the key entirely for `none`.
  test "Option.some encodes as the inner value (no wrapper)":
    let v = WireWithOption(label: "x", note: some("hi"))
    let bytes = cborEncode(v)
    check toHex(bytes) == "a2656c6162656c6178646e6f7465626869"

  test "Option.none yields a smaller map without the optional key":
    let v = WireWithOption(label: "x", note: none(string))
    let bytes = cborEncode(v)
    check toHex(bytes) == "a1656c6162656c6178"

suite "wire format — seq[T]":
  test "empty seq encodes as CBOR array(0)":
    let v = WireWithVector(items: @[])
    let bytes = cborEncode(v)
    check toHex(bytes) == "a1656974656d7380"

  test "three-element seq[string]":
    let v = WireWithVector(items: @["a", "bb", "ccc"])
    let bytes = cborEncode(v)
    check toHex(bytes) == "a1656974656d7383616162626263636363"

suite "wire format — seq[byte]":
  ## `seq[byte]` rides as a CBOR byte string (major type 2), never an array.
  test "seq[byte] field rides as a CBOR byte string, not an array":
    let v = WireWithBytes(blob: @[1'u8, 2'u8, 3'u8])
    let bytes = cborEncode(v)
    check toHex(bytes) == "a164626c6f6243010203"
    let valMajor = bytes[6]
    check valMajor >= 0x40'u8
    check valMajor <= 0x5b'u8
    let back = cborDecode(bytes, WireWithBytes)
    check back.isOk
    check back.value.blob == v.blob

  test "empty seq[byte] field rides as byte-string(0)":
    let v = WireWithBytes(blob: @[])
    let bytes = cborEncode(v)
    check toHex(bytes) == "a164626c6f6240"

suite "wire format — seq[byte] nested in a seq-of-struct":
  ## A `seq[byte]` field in a struct that is a `seq` element must stay a CBOR
  ## byte string (major type 2) at depth. Every backend must match this wire
  ## contract. The Rust generator broke it and wrote a `Vec<u8>` integer array.
  test "each nested seq[byte] rides as a byte string, request and response alike":
    let v = WireNestedBytes(
      entries: @[
        WireBytesEntry(id: "s0", data: @[0xAA'u8, 0xBB'u8]),
        WireBytesEntry(id: "s1", data: @[1'u8, 2'u8, 3'u8]),
      ]
    )
    let bytes = cborEncode(v)
    check toHex(bytes) ==
      "a167656e747269657382a2626964627330646461746142aabba26269646273316464617461" &
      "43010203"
    # The payloads must use byte-string headers (0x42 = bytes(2), 0x43 =
    # bytes(3)), not array headers (0x82 or 0x83).
    check "6461746142aabb" in toHex(bytes) # "data" + 0x42 <AA BB>
    check "6461746143010203" in toHex(bytes) # "data" + 0x43 <01 02 03>
    let back = cborDecode(bytes, WireNestedBytes)
    check back.isOk
    check back.value.entries.len == 2
    check back.value.entries[0].data == @[0xAA'u8, 0xBB'u8]
    check back.value.entries[1].data == @[1'u8, 2'u8, 3'u8]

  test "empty and multi-byte-length nested seq[byte] round-trip":
    let v = WireNestedBytes(
      entries: @[
        WireBytesEntry(id: "", data: @[]),
        WireBytesEntry(id: "big", data: newSeq[byte](30)),
      ]
    )
    let back = cborDecode(cborEncode(v), WireNestedBytes)
    check back.isOk
    check back.value.entries[0].data.len == 0
    check back.value.entries[1].data.len == 30
