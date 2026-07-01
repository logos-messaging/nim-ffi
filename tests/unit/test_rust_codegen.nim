## Regression tests for the Rust type mapping. `nimTypeToRust` used to carry its
## own scalar table that had drifted from C/C++ — `int8`/`int16`/`uint8`/
## `uint16`/`uint32`/`byte`/`float32` fell through to `capitalizeFirstLetter`
## and emitted invalid Rust. It now renders through the shared `parseFFIType`
## IR, so the full scalar set is pinned here.

import unittest2
import ffi/codegen/rust

suite "nimTypeToRust: scalar set":
  test "every scalar maps to its Rust primitive (the drift that regressed)":
    check nimTypeToRust("bool") == "bool"
    check nimTypeToRust("int8") == "i8"
    check nimTypeToRust("int16") == "i16"
    check nimTypeToRust("int32") == "i32"
    check nimTypeToRust("int") == "i64"
    check nimTypeToRust("int64") == "i64"
    check nimTypeToRust("uint8") == "u8"
    check nimTypeToRust("byte") == "u8"
    check nimTypeToRust("uint16") == "u16"
    check nimTypeToRust("uint32") == "u32"
    check nimTypeToRust("uint") == "u64"
    check nimTypeToRust("uint64") == "u64"
    check nimTypeToRust("float32") == "f32"
    check nimTypeToRust("float") == "f64"
    check nimTypeToRust("float64") == "f64"

suite "nimTypeToRust: strings, pointers and containers":
  test "string types render to String":
    check nimTypeToRust("string") == "String"
    check nimTypeToRust("cstring") == "String"

  test "seq[byte] collapses to Vec<u8> and ptr/pointer to the wire int":
    check nimTypeToRust("seq[byte]") == "Vec<u8>"
    check nimTypeToRust("ptr Foo") == RustPtrType
    check nimTypeToRust("pointer") == RustPtrType

  test "generics nest and Maybe aliases Option":
    check nimTypeToRust("seq[Option[int8]]") == "Vec<Option<i8>>"
    check nimTypeToRust("Maybe[uint16]") == "Option<u16>"

  test "an unknown user type is capitalised, not mistaken for a scalar":
    check nimTypeToRust("echoRequest") == "EchoRequest"
