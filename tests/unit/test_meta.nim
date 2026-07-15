## Unit tests for the AST helpers used by the FFI macro.

import unittest
import std/[macros, strutils]
import ffi/internal/ffi_macro

suite "unpackReqField":
  ## Runs in `static:` blocks (a failed doAssert becomes a compile error).
  ## AST repr whitespace is normalised so assertions are layout-stable.
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
    # Non-nnkIdent types must not trigger the cstring branch.
    static:
      let userType = nnkBracketExpr.newTree(ident("seq"), ident("int"))
      let node = unpackReqField(ident("xs"), userType, ident("decoded"))
      doAssert normalise(node.repr) == "let xs = decoded.xs"

  test "decoded identifier is used verbatim":
    static:
      let node = unpackReqField(ident("delayMs"), ident("int"), ident("myDecodedReq"))
      doAssert normalise(node.repr) == "let delayMs = myDecodedReq.delayMs"
