import std/[os, strutils]
import unittest2

# The validation only fires when --nimMainPrefix is on the command line, so we
# capture a real `nim check` of the fixture at this test's compile time.
# `mainprefix_fixture.nim` deliberately lacks the `test_` prefix so the nimble
# runner never compiles it standalone.
const
  nimExe = getCurrentCompilerExe()
  fixture = currentSourcePath.parentDir / "mainprefix_fixture.nim"
  checkCmd = nimExe & " check --hints:off --colors:off "
  wrongPrefixOutput = staticExec(checkCmd & "--nimMainPrefix:libWRONG " & fixture)
  rightPrefixOutput = staticExec(checkCmd & "--nimMainPrefix:libmpfixture " & fixture)

suite "compile-time --nimMainPrefix validation":
  test "a mismatched prefix errors and names the expected flag":
    check "Error:" in wrongPrefixOutput
    # naming the expected flag is what distinguishes our error from any other
    # compile failure, so assert on it rather than the bare "Error:".
    check "needs --nimMainPrefix:libmpfixture" in wrongPrefixOutput

  test "the matching prefix compiles without error":
    check "Error:" notin rightPrefixOutput
