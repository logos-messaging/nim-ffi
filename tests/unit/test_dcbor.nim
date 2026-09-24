## Logos deterministic CBOR conformance (LOGOS-MODULE-INTERFACE 4.4 / 4.5).
##
## Build with -d:ffiDeterministicCbor to exercise the codec seam as well; the
## profile tests below hold either way.
import std/[unittest, strutils]
import ../../ffi/dcbor
import cbor_serialization

proc hx(s: seq[byte]): string =
  result = ""
  for b in s: result.add(toHex(b, 2).toLowerAscii())

proc bs(s: string): seq[byte] =
  result = @[]
  for i in countup(0, s.len - 2, 2):
    result.add(byte(parseHexInt(s[i .. i + 1])))

suite "dCBOR profile: what must be rejected (4.5)":
  test "rule 1: map keys out of canonical order":
    check not validate(bs("a2647a65746101616102"))
  test "rule 2: non-shortest head":
    check not validate(bs("1801"))
  test "rule 3: indefinite length":
    check not validate(bs("9f0102ff"))
  test "rule 4: duplicate map keys":
    check not validate(bs("a2616101616102"))
  test "rule 5: floats":
    check not validate(bs("fa3fc00000"))
  test "tags":
    check not validate(bs("c11a514b67b0"))
  test "trailing bytes":
    check not validate(bs("0101"))
  test "text that is not valid UTF-8":
    check not validate(bs("62c328"))
  test "conformant bytes pass":
    check validate(bs("a2616102647a65746101"))
  test "empty payload passes":
    check validate(@[])

suite "canonicalisation fixes only what may be fixed":
  test "mis-ordered keys are reordered":
    check hx(canonicalise(bs("a2647a65746101616102"))) == "a2616102647a65746101"
  test "nested maps are reordered recursively":
    check hx(canonicalise(bs("a1656f75746572a2616201616102"))) ==
      "a1656f75746572a2616102616201"
  test "a float cannot be canonicalised":
    expect DcborError: discard canonicalise(bs("fa3fc00000"))
  test "a duplicate key cannot be canonicalised":
    expect DcborError: discard canonicalise(bs("a2616101616102"))
  test "canonicalise is idempotent":
    let once = canonicalise(bs("a2647a65746101616102"))
    check canonicalise(once) == once

suite "cbor_serialization is made conformant":
  test "declaration order is not conformant, and canonicalise fixes it":
    type T = object
      zeta: int
      a: int
    let raw = Cbor.encode(T(zeta: 1, a: 2))
    check not validate(raw)
    let fixed = canonicalise(raw)
    check validate(fixed)
    check hx(fixed) == "a2616102647a65746101"

  test "a float payload is refused rather than silently shipped":
    type F = object
      f: float64
    expect DcborError: discard canonicalise(Cbor.encode(F(f: 1.5)))
