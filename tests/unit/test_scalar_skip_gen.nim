## Drives the scalar-fast-path genBindings() behavior end to end: compiles
## `fixtures/scalar_skip_fixture.nim` (a library with an all-scalar `abi = c`
## proc) with `-d:ffiGenBindings` and asserts a CBOR-speaking target
## (`targetLang=c`) fails loudly, `-d:ffiAllowScalarSkip` downgrades the drop
## to a clean build, and `targetLang=c_abi` needs no skip at all — it emits a
## real binding for the scalar proc.
##
## The fixture is compiled in a child `nim check` (search paths and compiler
## captured at compile time) so an expected failure is observed as a test
## assertion, not this file's own compile error.

import std/[os, osproc, strutils, compilesettings]
import unittest2

const
  fixture = currentSourcePath().parentDir() / "fixtures" / "scalar_skip_fixture.nim"
  nimExe = getCurrentCompilerExe()
  ffiSearchPaths = querySettingSeq(searchPaths)

proc genFixture(
    lang: string, extraDefs: seq[string], outDir: string
): tuple[output: string, exitCode: int] =
  let cacheDir = getTempDir() / "ffi_scalar_skip_cache"
  createDir(outDir)
  var cmd = quoteShell(nimExe) & " check --hints:off --warnings:off"
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" -d:ffiGenBindings -d:targetLang=" & lang)
  cmd.add(" -d:ffiOutputDir=" & quoteShell(outDir))
  for d in extraDefs:
    cmd.add(" " & d)
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  cmd.add(" " & quoteShell(fixture))
  execCmdEx(cmd)

suite "scalar-fast-path drop is loud under -d:ffiGenBindings":
  test "a CBOR target errors and names the dropped scalar proc":
    let (output, code) = genFixture("c", @[], getTempDir() / "ffi_scalar_skip_out_c")
    check code != 0
    check output.contains("scalarskip_add")
    check output.contains("scalar-fast-path")
    check output.contains("targetLang=c_abi")
    check output.contains("-d:ffiAllowScalarSkip")

  test "-d:ffiAllowScalarSkip downgrades the drop to a clean build":
    let (output, code) = genFixture(
      "c", @["-d:ffiAllowScalarSkip"], getTempDir() / "ffi_scalar_skip_out_c_skip"
    )
    check code == 0
    check not output.contains("Error")

  test "targetLang=c_abi needs no skip: the scalar proc has real codegen":
    # `nim check` runs genBindings() but VM file writes are skipped, so this
    # asserts the clean build only; the emitted wrapper text is covered by
    # test_c_abi_codegen and the checked-in echo c_abi bindings.
    let (output, code) =
      genFixture("c_abi", @[], getTempDir() / "ffi_scalar_skip_out_c_abi")
    check code == 0
    check not output.contains("Error")
