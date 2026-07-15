import std/[os, strutils]
import unittest2

# Captures a real `nim check` of the fixture at compile time, with/without --nimMainPrefix.
const
  nimExe = getCurrentCompilerExe()
  fixture = currentSourcePath.parentDir / "mainprefix_fixture.nim"
  checkCmd = nimExe & " check --hints:off --colors:off "
  wrongPrefixOutput = staticExec(checkCmd & "--nimMainPrefix:libWRONG " & fixture)
  rightPrefixOutput = staticExec(checkCmd & "--nimMainPrefix:libmpfixture " & fixture)

suite "compile-time --nimMainPrefix validation":
  test "a mismatched prefix errors and names the expected flag":
    check "Error:" in wrongPrefixOutput
    # Assert on the flag name to distinguish our error from any other compile failure.
    check "needs --nimMainPrefix:libmpfixture" in wrongPrefixOutput

  test "the matching prefix compiles without error":
    check "Error:" notin rightPrefixOutput
