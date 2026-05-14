## Unit tests for the string-manipulation helpers used by the codegen.
## These names map identifier conventions between Nim (camelCase),
## Rust (snake_case) and C++ (PascalCase types), and they're load-bearing
## for binding generation, so it's worth pinning their behaviour with tests.

import unittest
import std/[macros, strutils]
import ../ffi/codegen/meta
import ../ffi/internal/ffi_macro

suite "camelToSnakeCase":
  test "empty string":
    check camelToSnakeCase("") == ""

  test "single lowercase character":
    check camelToSnakeCase("a") == "a"

  test "single uppercase character":
    check camelToSnakeCase("A") == "a"

  test "all lowercase passes through":
    check camelToSnakeCase("hello") == "hello"

  test "simple camelCase":
    check camelToSnakeCase("camelCase") == "camel_case"

  test "two-letter suffix":
    check camelToSnakeCase("delayMs") == "delay_ms"

  test "PascalCase input — leading capital stays at start":
    check camelToSnakeCase("PascalCase") == "pascal_case"

  test "consecutive uppercase letters each get their own underscore":
    check camelToSnakeCase("ABC") == "a_b_c"

  test "multiple word boundaries":
    check camelToSnakeCase("abcDefGhi") == "abc_def_ghi"

  test "already snake_case passes through":
    check camelToSnakeCase("already_snake") == "already_snake"

suite "capitalizeFirstLetter":
  test "empty string":
    check capitalizeFirstLetter("") == ""

  test "single lowercase character":
    check capitalizeFirstLetter("a") == "A"

  test "single uppercase character":
    check capitalizeFirstLetter("A") == "A"

  test "lowercase word":
    check capitalizeFirstLetter("abc") == "Abc"

  test "already capitalised":
    check capitalizeFirstLetter("Abc") == "Abc"

  test "all-caps stays unchanged except first stays cap":
    check capitalizeFirstLetter("ABC") == "ABC"

  test "leading non-letter is left alone":
    check capitalizeFirstLetter("_hello") == "_hello"

suite "snakeToPascalCase":
  test "empty string":
    check snakeToPascalCase("") == ""

  test "single lowercase word":
    check snakeToPascalCase("hello") == "Hello"

  test "two-part snake_case":
    check snakeToPascalCase("hello_world") == "HelloWorld"

  test "three-part snake_case":
    check snakeToPascalCase("testlib_create") == "TestlibCreate"

  test "single-letter parts each capitalised":
    check snakeToPascalCase("a_b_c") == "ABC"

  test "trailing underscore yields empty trailing part":
    check snakeToPascalCase("foo_") == "Foo"

  test "leading underscore yields empty leading part":
    check snakeToPascalCase("_foo") == "Foo"

  test "already-mixed parts preserve their existing case after the first":
    # split on '_', capitalize first letter of each part; "HasCaps" first
    # letter is already 'H' so it's untouched.
    check snakeToPascalCase("already_HasCaps") == "AlreadyHasCaps"

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
      let node =
        unpackReqField(ident("message"), ident("cstring"), ident("decoded"))
      doAssert normalise(node.repr) ==
        "let message: cstring = decoded.message.cstring"

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
      let node =
        unpackReqField(ident("delayMs"), ident("int"), ident("myDecodedReq"))
      doAssert normalise(node.repr) == "let delayMs = myDecodedReq.delayMs"
