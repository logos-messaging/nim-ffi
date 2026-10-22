## End-to-end generation over tests/unit/fixtures/codegen_types_fixture.nim:
## how the generated bindings name and encode what a library's API declares.

import std/[os, strutils]
import unittest2
import ./fixture_gen

let cGen = genFixtureBindings("codegen_types_fixture", "c")
let cppGen = genFixtureBindings("codegen_types_fixture", "cpp")

suite "exported {.ffi.} fields":
  # `peerId*: string` is a postfix node in the macro; its `*` used to reach
  # the bindings as the field name and as the CBOR map key ("peerId*").
  test "the C header names them without the export marker":
    require cGen.exitCode == 0
    let header = readFile(cGen.outDir / "typeslib.h")
    check "const char* peerId;" in header
    check "\"peerId\"" in header
    check "peerId*" notin header

  test "the C++ header names them without the export marker":
    require cppGen.exitCode == 0
    let header = readFile(cppGen.outDir / "typeslib.hpp")
    check "std::string peerId;" in header
    check "\"peerId\"" in header
    check "peerId*" notin header
