## Runs each fixture in a child process under this run's --mm, so a crash stays in the child.

import std/[os, osproc, compilesettings]
import unittest2

const
  fixturesDir = currentSourcePath().parentDir() / "fixtures"
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

proc runFixture(name: string): tuple[output: string, exitCode: int] =
  let outDir = getTempDir() / ("ffi_" & name & "_out")
  let cacheDir = getTempDir() / ("ffi_" & name & "_cache")
  createDir(outDir)
  var cmd = quoteShell(nimExe) & " c -r --hints:off --warnings:off"
  if mmFlag.len > 0:
    cmd.add(" " & mmFlag)
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  # Write the binary to the temp directory. The fixture directory contains only source.
  cmd.add(" --outdir:" & quoteShell(outDir))
  cmd.add(" " & quoteShell(fixturesDir / (name & ".nim")))
  execCmdEx(cmd)

suite "entry points are callable from foreign host threads":
  test "method calls from unregistered host threads succeed":
    let (output, code) = runFixture("foreign_thread_fixture")
    checkpoint(output)
    check code == 0

suite "foreignThreadGc":
  test "a Nim thread keeps allocating after the block returns":
    let (output, code) = runFixture("foreign_thread_gc_fixture")
    checkpoint(output)
    check code == 0
