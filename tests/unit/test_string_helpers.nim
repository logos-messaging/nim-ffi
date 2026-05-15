## Unit tests for the identifier-casing helpers used by the codegen.
## These names map identifier conventions between Nim (camelCase),
## Rust (snake_case) and C++ (PascalCase types), and they're load-bearing
## for binding generation, so it's worth pinning their behaviour with tests.

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
