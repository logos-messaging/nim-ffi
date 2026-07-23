## Unit tests for the identifier-casing helpers used by the codegen.

import unittest
import ffi/codegen/string_helpers

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

suite "identToUpperSnake":
  test "empty string":
    check identToUpperSnake("") == ""

  test "camelCase":
    check identToUpperSnake("maxPeers") == "MAX_PEERS"

  test "PascalCase":
    check identToUpperSnake("MaxPeers") == "MAX_PEERS"

  test "already UPPER_SNAKE passes through":
    check identToUpperSnake("MAX_PEERS") == "MAX_PEERS"

  test "acronym run stays one word":
    check identToUpperSnake("HTTPPort") == "HTTP_PORT"

  test "acronym after a word":
    check identToUpperSnake("httpTTL") == "HTTP_TTL"

  test "digits don't split a word":
    check identToUpperSnake("v2Enabled") == "V2_ENABLED"

  test "single word":
    check identToUpperSnake("timeout") == "TIMEOUT"

  test "runs of underscores collapse":
    check identToUpperSnake("a__b") == "A_B"

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
    # Existing caps after the first letter of each part are preserved.
    check snakeToPascalCase("already_HasCaps") == "AlreadyHasCaps"

suite "renderDocComment":
  test "empty doc renders nothing":
    check renderDocComment("", "", "/// ").len == 0

  test "blank doc renders nothing":
    check renderDocComment("  \n  ", "", "/// ").len == 0

  test "single line gets the prefix":
    check renderDocComment("does a thing", "", "/// ") == @["/// does a thing"]

  test "each line gets prefix and indent":
    check renderDocComment("one\ntwo", "    ", "/// ") == @[
      "    /// one", "    /// two"
    ]

  test "a blank interior line keeps no trailing whitespace":
    check renderDocComment("one\n\ntwo", "", "/// ") == @["/// one", "///", "/// two"]

  test "trailing blank lines are dropped":
    check renderDocComment("one\n\n", "", "; ") == @["; one"]

  test "a trailing backslash cannot splice the next line into the comment":
    check renderDocComment("one \\\ntwo", "", "/// ") == @["/// one", "/// two"]

suite "renderBlockDocComment":
  test "empty doc renders nothing":
    check renderBlockDocComment("", "").len == 0

  test "single line collapses to a one-line block":
    check renderBlockDocComment("does a thing", "") == @["/** does a thing */"]

  test "multiple lines render a star block":
    check renderBlockDocComment("one\ntwo", "") == @["/**", " * one", " * two", " */"]

  test "indent applies to every line of the block":
    check renderBlockDocComment("one\ntwo", "  ") ==
      @["  /**", "   * one", "   * two", "   */"]

  test "a blank interior line keeps no trailing whitespace":
    check renderBlockDocComment("one\n\ntwo", "") ==
      @["/**", " * one", " *", " * two", " */"]

  test "a one-liner cannot close its own comment early":
    check renderBlockDocComment("Frees it. */ #define OOPS 1 /* x", "") ==
      @["/** Frees it. * / #define OOPS 1 /* x */"]

  test "a star block cannot close its own comment early":
    check renderBlockDocComment("one */ #define OOPS 1\ntwo", "") ==
      @["/**", " * one * / #define OOPS 1", " * two", " */"]
