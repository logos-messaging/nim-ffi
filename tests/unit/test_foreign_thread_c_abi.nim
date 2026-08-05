## This test runs the fixture in a child process. The fixture calls `abi = c`
## entry points from threads that the Nim runtime does not know. A regression
## crashes the child, not this suite. The child uses the same --mm switch as
## this run. The regression is fatal under refc and harmless under orc.

import std/[os, osproc, compilesettings]
import unittest2

const
  fixture =
    currentSourcePath().parentDir() / "fixtures" / "foreign_thread_c_abi_fixture.nim"
  nimExe = getCurrentCompilerExe()
  ffiSearchPaths = querySettingSeq(searchPaths)
  mmFlag =
    when compileOption("mm", "refc"):
      "--mm:refc"
    elif compileOption("mm", "orc"):
      "--mm:orc"
    elif compileOption("mm", "arc"):
      "--mm:arc"
    else:
      ""

proc runFixture(): tuple[output: string, exitCode: int] =
  let outDir = getTempDir() / "ffi_foreign_thread_out"
  let cacheDir = getTempDir() / "ffi_foreign_thread_cache"
  createDir(outDir)
  var cmd = quoteShell(nimExe) & " c -r --hints:off --warnings:off"
  if mmFlag.len > 0:
    cmd.add(" " & mmFlag)
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  # Write the binary to the temp directory. The fixture directory contains only source.
  cmd.add(" --outdir:" & quoteShell(outDir))
  cmd.add(" " & quoteShell(fixture))
  execCmdEx(cmd)

suite "abi = c entry points are callable from foreign host threads":
  test "method calls from unregistered host threads succeed":
    let (output, code) = runFixture()
    checkpoint(output)
    check code == 0
