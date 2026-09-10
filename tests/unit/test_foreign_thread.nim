## Runs the fixture in a child process, under the same --mm switch as this run:
## the fixture calls entry points from threads the Nim runtime does not know, and
## a regression crashes the child rather than this suite (fatal under refc only).

import std/[os, osproc, compilesettings]
import unittest2

const
  fixture = currentSourcePath().parentDir() / "fixtures" / "foreign_thread_fixture.nim"
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

suite "entry points are callable from foreign host threads":
  test "method calls from unregistered host threads succeed":
    let (output, code) = runFixture()
    checkpoint(output)
    check code == 0
