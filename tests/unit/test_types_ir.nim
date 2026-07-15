## Unit tests for `parseFFIType`, the shared type IR the C / C++ / Rust backends consume.

import unittest2
import ffi/codegen/types_ir

suite "parseFFIType: scalars":
  test "the full scalar set round-trips to its ScalarKind":
    let cases = {
      "bool": skBool,
      "int8": skI8,
      "int16": skI16,
      "int32": skI32,
      "int": skI64,
      "int64": skI64,
      "uint8": skU8,
      "byte": skU8,
      "uint16": skU16,
      "uint32": skU32,
      "uint": skU64,
      "uint64": skU64,
      "float32": skF32,
      "float": skF64,
      "float64": skF64,
    }
    for (name, kind) in cases:
      let t = parseFFIType(name)
      check t.kind == ftScalar
      check t.scalar == kind

  test "surrounding whitespace is stripped":
    let t = parseFFIType("  int  ")
    check t.kind == ftScalar
    check t.scalar == skI64

suite "parseFFIType: strings, bytes and pointers":
  test "string and cstring are ftStr":
    check parseFFIType("string").kind == ftStr
    check parseFFIType("cstring").kind == ftStr

  test "seq[byte] and seq[uint8] collapse to ftBytes":
    check parseFFIType("seq[byte]").kind == ftBytes
    check parseFFIType("seq[uint8]").kind == ftBytes

  test "ptr T and pointer are ftPtr":
    check parseFFIType("ptr Foo").kind == ftPtr
    check parseFFIType("pointer").kind == ftPtr

suite "parseFFIType: containers":
  test "seq[T] wraps the parsed element":
    let t = parseFFIType("seq[int]")
    check t.kind == ftSeq
    check t.elem.kind == ftScalar
    check t.elem.scalar == skI64

  test "Maybe[T] is the same as Option[T]":
    let opt = parseFFIType("Option[string]")
    let maybe = parseFFIType("Maybe[string]")
    check opt.kind == ftOpt
    check maybe.kind == ftOpt
    check opt.elem.kind == ftStr
    check maybe.elem.kind == ftStr

  test "nested containers parse all the way down":
    let t = parseFFIType("seq[Option[seq[int]]]")
    check t.kind == ftSeq
    check t.elem.kind == ftOpt
    check t.elem.elem.kind == ftSeq
    check t.elem.elem.elem.kind == ftScalar
    check t.elem.elem.elem.scalar == skI64

  test "seq[Option[byte]] keeps the inner byte as a scalar, not bytes":
    let t = parseFFIType("seq[Option[byte]]")
    check t.kind == ftSeq
    check t.elem.kind == ftOpt
    check t.elem.elem.kind == ftScalar
    check t.elem.elem.scalar == skU8

suite "parseFFIType: structs":
  test "an unknown name is an ftStruct carrying the name":
    let t = parseFFIType("EchoRequest")
    check t.kind == ftStruct
    check t.name == "EchoRequest"

suite "renderNative: walks the intermediate representation with a backend map":
  let rustish = NativeTypeMap(
    scalar: proc(s: ScalarKind): string =
      (
        case s
        of skI64: "i64"
        of skU8: "u8"
        else: "?"
      ),
    str: "String",
    bytes: "Vec<u8>",
    ptrType: "u64",
    seqOf: proc(e: string): string =
      "Vec<" & e & ">",
    optOf: proc(e: string): string =
      "Option<" & e & ">",
    structName: proc(n: string): string =
      n,
  )

  test "scalars, strings, bytes and pointers map to the leaf entries":
    check renderNative(rustish, parseFFIType("int")) == "i64"
    check renderNative(rustish, parseFFIType("string")) == "String"
    check renderNative(rustish, parseFFIType("seq[byte]")) == "Vec<u8>"
    check renderNative(rustish, parseFFIType("ptr Foo")) == "u64"

  test "nested containers render recursively":
    check renderNative(rustish, parseFFIType("seq[Option[int]]")) == "Vec<Option<i64>>"

  test "a struct renders through structName when set":
    check renderNative(rustish, parseFFIType("EchoRequest")) == "EchoRequest"

  test "a nil structName passes the user type name through unchanged":
    let noStructMap = NativeTypeMap(
      scalar: rustish.scalar, str: "String", bytes: "Vec<u8>", ptrType: "u64"
    )
    check renderNative(noStructMap, parseFFIType("EchoRequest")) == "EchoRequest"
