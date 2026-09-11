## Runs the fixture in a child process, under the same --mm switch as this run:
## `foreignThreadGc` must not leave the calling thread without an allocator
## region handle, and a regression crashes or hangs the child rather than this
## suite.
##
## Only Nim >= 2.2.12 under --mm:orc/--mm:arc can actually observe the
## regression; on earlier compilers `tearDownForeignThreadGc` was a no-op
## template under ARC/ORC, and under --mm:refc it early-returns for threads that
## are not foreign. The test is kept unconditional so it keeps guarding the
## template as the floor compiler moves.

import std/[os, osproc, strutils, compilesettings]
import unittest2
import ffi/ffi_types

# The guard must stay narrow. It exists to avoid a destructive teardown on
# Nim >= 2.2.12 under ARC/ORC, and must not fire on the configurations where the
# teardown was harmless — otherwise a genuinely foreign thread entering through
# the template would silently stop releasing its refc GC state. Stated in terms
# of the memory manager rather than the const's own formula, so a wrong edit to
# `ffiForeignGcTeardownIsDestructive` trips this at compile time.
static:
  when compileOption("mm", "refc"):
    doAssert not ffiForeignGcTeardownIsDestructive,
      "refc guards tearDownForeignThreadGc itself; it must keep being called"
  when compileOption("mm", "orc") and (NimMajor, NimMinor, NimPatch) < (2, 2, 12):
    doAssert not ffiForeignGcTeardownIsDestructive,
      "ARC/ORC before 2.2.12 stubbed the teardown; behaviour must be unchanged"
  when compileOption("mm", "orc") and (NimMajor, NimMinor, NimPatch) >= (2, 2, 12):
    doAssert ffiForeignGcTeardownIsDestructive,
      "ORC from 2.2.12 releases the region handle; the teardown must be skipped"

const
  fixture =
    currentSourcePath().parentDir() / "fixtures" / "foreign_thread_gc_fixture.nim"
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
  let outDir = getTempDir() / "ffi_foreign_thread_gc_out"
  let cacheDir = getTempDir() / "ffi_foreign_thread_gc_cache"
  createDir(outDir)
  var cmd = quoteShell(nimExe) & " c -r --hints:off --warnings:off"
  if mmFlag.len > 0:
    cmd.add(" " & mmFlag)
  cmd.add(" --threads:on")
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  cmd.add(" --outdir:" & quoteShell(outDir))
  cmd.add(" " & quoteShell(fixture))
  execCmdEx(cmd)

suite "foreignThreadGc leaves the calling thread able to allocate":
  test "a long-lived Nim thread keeps allocating across the block":
    let (output, code) = runFixture()
    checkpoint(output)
    check code == 0
    check output.contains("fixture OK")
