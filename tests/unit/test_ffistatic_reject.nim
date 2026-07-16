## Asserts `{.ffiStatic.}` rejects what cannot cross a context-independent proc:
## an {.ffiHandle.} parameter or return (both are resolved against the context
## that owns them), and an `abi = c` scalar return (no reply shape without the
## ctx-bound fast path).
##
## Each fixture compiles in a child `nim check` so its expected failure is a test
## assertion, not this file's own compile error.

import std/[os, osproc, strutils, compilesettings]
import unittest2

const
  fixtureDir = currentSourcePath().parentDir() / "fixtures"
  nimExe = getCurrentCompilerExe()
  ffiSearchPaths = querySettingSeq(searchPaths)

proc checkFixture(name: string): tuple[output: string, exitCode: int] =
  let cacheDir = getTempDir() / "ffi_ffistatic_reject_cache" / name
  var cmd = quoteShell(nimExe) & " check --hints:off --warnings:off"
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  cmd.add(" " & quoteShell(fixtureDir / (name & "_fixture.nim")))
  execCmdEx(cmd)

suite "{.ffiStatic.} rejects handles at macro time":
  test "an {.ffiHandle.} parameter fails the build, naming the proc and the fix":
    let (output, code) = checkFixture("ffistatic_handle_param")
    check code != 0
    check output.contains("staticrejBad")
    check output.contains("Session")
    check output.contains("`{.ffi.}` method instead")

  test "an {.ffiHandle.} return fails the build, naming the proc and the fix":
    let (output, code) = checkFixture("ffistatic_handle_return")
    check code != 0
    check output.contains("staticrejBad")
    check output.contains("Session")
    check output.contains("`{.ffi.}` method instead")

  test "the same shapes without handles compile":
    let (output, code) = checkFixture("ffistatic_ok")
    check code == 0
    check not output.contains("Error")

suite "{.ffiStatic.} rejects an abi = c scalar return":
  test "the error names the proc and the wired reply shapes, not int_CWire":
    let (output, code) = checkFixture("ffistatic_abi_c_scalar")
    check code != 0
    check output.contains("staticscalar_add")
    check output.contains("unsupported response type")
    check not output.contains("int_CWire")
