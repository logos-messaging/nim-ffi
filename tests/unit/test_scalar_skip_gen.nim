## Drives the scalar-fast-path drop error end to end: compiles
## `fixtures/scalar_skip_fixture.nim` (a library with an all-scalar `abi = c`
## proc) with `-d:ffiGenBindings` and asserts genBindings() fails loudly, and
## that `-d:ffiAllowScalarSkip` downgrades the drop to a clean build.
##
## The fixture is compiled in a child `nim check` (search paths and compiler
## captured at compile time) so its expected failure is observed as a test
## assertion, not this file's own compile error.

import std/[os, osproc, strutils, compilesettings]
import unittest2

const
  fixture = currentSourcePath().parentDir() / "fixtures" / "scalar_skip_fixture.nim"
  nimExe = getCurrentCompilerExe()
  ffiSearchPaths = querySettingSeq(searchPaths)

proc genFixture(extraDefs: seq[string]): tuple[output: string, exitCode: int] =
  let outDir = getTempDir() / "ffi_scalar_skip_out"
  let cacheDir = getTempDir() / "ffi_scalar_skip_cache"
  createDir(outDir)
  var cmd = quoteShell(nimExe) & " check --hints:off --warnings:off"
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" -d:ffiGenBindings -d:targetLang=c")
  cmd.add(" -d:ffiOutputDir=" & quoteShell(outDir))
  for d in extraDefs:
    cmd.add(" " & d)
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  cmd.add(" " & quoteShell(fixture))
  execCmdEx(cmd)

suite "scalar-fast-path drop is loud under -d:ffiGenBindings":
  test "genBindings errors and names the dropped scalar proc":
    let (output, code) = genFixture(@[])
    check code != 0
    check output.contains("scalarskip_add")
    check output.contains("scalar-fast-path")
    check output.contains("-d:ffiAllowScalarSkip")

  test "-d:ffiAllowScalarSkip downgrades the drop to a clean build":
    let (output, code) = genFixture(@["-d:ffiAllowScalarSkip"])
    check code == 0
    check not output.contains("Error")
