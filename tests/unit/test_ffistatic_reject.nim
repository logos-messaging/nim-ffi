## Asserts `{.ffiStatic.}` rejects an {.ffiHandle.} param and an {.ffiHandle.}
## return. Each fixture compiles in a child `nim check`, so the expected failure
## is an assertion, not this file's own compile error.

import std/strutils
import unittest2
import ./fixture_gen

suite "{.ffiStatic.} rejects handles at macro time":
  test "an {.ffiHandle.} parameter fails the build, naming the proc and the fix":
    let (output, code) = checkFixture("ffistatic_handle_param_fixture")
    check code != 0
    check output.contains("staticrejBad")
    check output.contains("Session")
    check output.contains("`{.ffi.}` method instead")

  test "an {.ffiHandle.} return fails the build, naming the proc and the fix":
    let (output, code) = checkFixture("ffistatic_handle_return_fixture")
    check code != 0
    check output.contains("staticrejBad")
    check output.contains("Session")
    check output.contains("`{.ffi.}` method instead")

  test "the same shapes without handles compile":
    let (output, code) = checkFixture("ffistatic_ok_fixture")
    check code == 0
    check not output.contains("Error")
