## Unit tests for the AST helpers used by the FFI macro.
## The identifier-casing helpers used to live here too; they now have their
## own module and test file (`test_string_helpers.nim`).

import unittest
import std/[macros, strutils]
import ffi/internal/ffi_macro

suite "unpackReqField":
  ## `unpackReqField` builds AST via `std/macros` helpers (`ident`, `newDotExpr`,
  ## `newLetStmt`, etc.) which are compile-time magics. The tests therefore run
  ## as `static:` blocks — a failed `doAssert` becomes a compile-time error, so
  ## a broken helper aborts the build before the test binary is produced.
  ## Whitespace in AST repr is normalised so the assertions are layout-stable.
  proc normalise(s: string): string {.compileTime.} =
    var buf = ""
    var prevSpace = true
    for c in s:
      if c in {' ', '\t', '\n', '\r'}:
        if not prevSpace:
          buf.add(' ')
        prevSpace = true
      else:
        buf.add(c)
        prevSpace = false
    return buf.strip()

  test "non-cstring field unpacks as plain assignment":
    static:
      let node = unpackReqField(ident("count"), ident("int"), ident("decoded"))
      doAssert normalise(node.repr) == "let count = decoded.count"

  test "cstring field unpacks with .cstring cast":
    static:
      let node = unpackReqField(ident("message"), ident("cstring"), ident("decoded"))
      doAssert normalise(node.repr) == "let message: cstring = decoded.message.cstring"

  test "non-cstring (string) does NOT add the .cstring cast":
    static:
      let node = unpackReqField(ident("name"), ident("string"), ident("decoded"))
      let r = normalise(node.repr)
      doAssert r == "let name = decoded.name"
      doAssert ".cstring" notin r

  test "non-cstring complex type passes through unchanged":
    # Generic / bracket / dot expressions are not nnkIdent, so the cstring
    # branch must not fire even if the type's textual repr contains "cstring".
    static:
      let userType = nnkBracketExpr.newTree(ident("seq"), ident("int"))
      let node = unpackReqField(ident("xs"), userType, ident("decoded"))
      doAssert normalise(node.repr) == "let xs = decoded.xs"

  test "decoded identifier is used verbatim":
    static:
      let node = unpackReqField(ident("delayMs"), ident("int"), ident("myDecodedReq"))
      doAssert normalise(node.repr) == "let delayMs = myDecodedReq.delayMs"
