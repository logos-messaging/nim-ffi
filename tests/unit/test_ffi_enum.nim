## Unit tests for `{.ffi.}` enums: per-backend rendering of a synthetic registry,
## a Nim-side CBOR round-trip, and an end-to-end generation run over a fixture.

import std/[os, strutils]
import unittest2
import ./fixture_gen
import ffi
import ffi/codegen/[meta, c, cpp, rust, cddl]

proc enumValue(name, wire: string, ord: int): FFIEnumValueMeta =
  FFIEnumValueMeta(name: name, wire: wire, ord: ord)

let colorMeta = FFITypeMeta(
  name: "Color",
  enumValues: @[enumValue("cRed", "cRed", 0), enumValue("cGreen", "green", 1)],
)

let paintMeta = FFITypeMeta(
  name: "PaintRequest", fields: @[FFIFieldMeta(name: "color", typeName: "Color")]
)

let ctor = FFIProcMeta(
  procName: "enumlib_create",
  libName: "enumlib",
  kind: FFIKind.CTOR,
  libTypeName: "EnumLib",
  returnTypeName: "EnumLib",
)

let paint = FFIProcMeta(
  procName: "enumlib_paint",
  libName: "enumlib",
  kind: FFIKind.FFI,
  libTypeName: "EnumLib",
  extraParams: @[FFIParamMeta(name: "color", typeName: "Color")],
  returnTypeName: "PaintRequest",
)

suite "enums in the C header":
  setup:
    let header = generateCLibHeader(@[ctor, paint], @[colorMeta, paintMeta], "enumlib")

  test "the enum becomes a C enum with explicit ordinals":
    check "typedef enum {" in header
    check "COLOR_C_RED = 0," in header
    check "COLOR_C_GREEN = 1" in header
    check "} Color;" in header

  test "the codec maps to the CBOR text form, not the ordinal":
    check "case COLOR_C_RED: return cbor_encode_text_stringz(e, \"cRed\");" in header
    check "case COLOR_C_GREEN: return cbor_encode_text_stringz(e, \"green\");" in header
    check "if (strcmp(buf, \"green\") == 0) { *out = COLOR_C_GREEN;" in header

  test "the decode buffer is sized to the longest wire name":
    # Wire forms are "cRed" (4) and "green" (5); the longest plus a NUL is 6.
    check "char buf[6];" in header

  test "an enum field is a plain member, not a nested struct":
    check "    Color color;" in header

  test "an enum param passes by value":
    check "int enumlib_ctx_paint(const EnumLibCtx* ctx, Color color," in header
    check "const Color* color" notin header

suite "enums in the C++ header":
  setup:
    let header = generateCppHeader(@[ctor, paint], @[colorMeta, paintMeta], "enumlib")

  test "the enum becomes a scoped enum class":
    check "enum class Color {" in header
    check "    cRed = 0," in header

  test "the codec is declared before the struct codec that calls it":
    check header.find("enum class Color") < header.find("struct PaintRequest")

  test "decode goes through the std::string overload":
    check "if (name == \"green\") { v = Color::cGreen; return CborNoError; }" in header

suite "enums in the Rust crate":
  setup:
    let typesRs = generateTypesRs(@[colorMeta, paintMeta], @[ctor, paint])

  test "the enum becomes a fieldless Rust enum":
    check "pub enum Color {" in typesRs
    check "    CRed," in typesRs

  test "serde renames each variant to its wire form":
    check "#[serde(rename = \"green\")]" in typesRs
    check "    CGreen," in typesRs

  test "a variant whose name already matches the wire form needs no rename":
    check "#[serde(rename = \"CRed\")]" notin typesRs

suite "enums in the CDDL schema":
  test "the rule is a choice of the wire strings":
    let schema =
      generateCddlSchema(@[ctor, paint], @[colorMeta, paintMeta], "enumlib", "x.nim")
    check "Color = \"cRed\" / \"green\"" in schema

type
  RoundTripColor {.ffi.} = enum
    rtRed
    rtBlue

  RoundTripLevel {.ffi.} = enum
    rtLow = "low"
    rtHigh = "high"

type RoundTripPaint {.ffi.} = object
  color: RoundTripColor
  level: RoundTripLevel

suite "enum CBOR round-trip on the Nim side":
  test "an enum field survives encode/decode":
    let sent = RoundTripPaint(color: rtBlue, level: rtHigh)
    let back = cborDecode(cborEncode(sent), RoundTripPaint)
    check back.isOk()
    check back.get() == sent

  test "the wire form is the associated string when the enum declares one":
    var wire = ""
    for b in cborEncode(RoundTripPaint(color: rtRed, level: rtLow)):
      wire.add(char(b))
    check "low" in wire
    check "rtRed" in wire

let genned = genFixtureBindings("enum_fixture", "c")

suite "{.ffi.} enum end-to-end generation":
  setup:
    require genned.exitCode == 0
    let header = readFile(genned.outDir / "enumlib.h")

  test "explicit ordinals and associated strings both survive to the C header":
    check "STATUS_ST_IDLE = 2," in header
    check "STATUS_ST_BUSY = 7" in header
    check "case LEVEL_L_LOW: return cbor_encode_text_stringz(e, \"low\");" in header

  test "an enum return reaches the host through the reply callback":
    check "(*EnumLibPickReplyFn)(int err_code, const Color* reply," in header
    check "int enumlib_ctx_pick(const EnumLibCtx* ctx, Level level," in header

suite "enums on the abi = c path are rejected, not silently mis-wired":
  test "an enum in an abi = c library fails to compile":
    let (output, code) = checkFixture("enum_abi_c_type_fixture")
    check code != 0
    check "`abi = c` does not support enum types yet" in output

  test "an enum reached from an abi = c type fails to compile":
    let (output, code) = checkFixture("enum_abi_c_field_fixture")
    check code != 0
    check "cwire: `abi = c` does not support enum types yet" in output
    check "Color" in output
