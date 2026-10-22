## End-to-end generation over tests/unit/fixtures/codegen_types_fixture.nim:
## how the generated bindings name and encode what a library's API declares.

import std/[os, osproc, strutils]
import unittest2
import ./fixture_gen

let cGen = genFixtureBindings("codegen_types_fixture", "c")
let cppGen = genFixtureBindings("codegen_types_fixture", "cpp")

const tinycborDir =
  currentSourcePath().parentDir().parentDir().parentDir() / "ffi" / "codegen" /
  "templates" / "cpp" / "vendor"

proc compileCppHeader(outDir, header: string): tuple[output: string, exitCode: int] =
  ## Syntax-checks a translation unit that includes the generated header, the
  ## way any C++ host compiles it.
  let tu = outDir / "include_check.cpp"
  writeFile(tu, "#include \"" & header & "\"\nint main() { return 0; }\n")
  let cxx = findExe("c++")
  let cmd =
    quoteShell(cxx) & " -std=c++20 -fsyntax-only -I" & quoteShell(outDir) & " -I" &
    quoteShell(tinycborDir) & " " & quoteShell(tu)
  return execCmdEx(cmd)

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

suite "generated C++ header compiles":
  # Before: a `uint32_t`/`uint16_t` converted equally well to the bool, int32,
  # int64 and uint64 encode_cbor overloads (ambiguous) and had no decode_cbor
  # overload at all; and the `relay_publish` method's unqualified call to the
  # raw `relay_publish` export resolved to the method itself.
  test "narrow integers, float32 and an unprefixed proc":
    require cppGen.exitCode == 0
    if findExe("c++").len == 0:
      skip()
    else:
      let (output, code) = compileCppHeader(cppGen.outDir, "typeslib.hpp")
      if code != 0:
        echo output
      check code == 0

  test "the unprefixed method calls its raw export, not itself":
    require cppGen.exitCode == 0
    let header = readFile(cppGen.outDir / "typeslib.hpp")
    check "return ::relay_publish(ptr_, cb, ud," in header
