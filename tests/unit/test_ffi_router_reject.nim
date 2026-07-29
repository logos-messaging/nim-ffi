## `{.ffi.}` routes on the shape, but the named pragmas still assert it. Each
## fixture compiles in a child `nim check`, so its expected failure is an
## assertion rather than this file's own compile error.

import std/[os, osproc, strutils, compilesettings]
import unittest2

const
  fixtureDir = currentSourcePath().parentDir() / "fixtures"
  nimExe = getCurrentCompilerExe()
  ffiSearchPaths = querySettingSeq(searchPaths)

proc checkFixture(name: string): tuple[output: string, exitCode: int] =
  let cacheDir = getTempDir() / "ffi_router_reject_cache" / name
  var cmd = quoteShell(nimExe) & " check --hints:off --warnings:off"
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  cmd.add(" " & quoteShell(fixtureDir / (name & "_fixture.nim")))
  execCmdEx(cmd)

suite "a named pragma asserts the shape it claims":
  test "{.ffiExport.} on a static shape names the proc and the right pragma":
    let (output, code) = checkFixture("router_export_wrong_shape")
    check code != 0
    check output.contains("routerrejBad")
    check output.contains("`.ffiStatic.`")

  test "{.ffiDtor.} on a method shape names the proc and the right pragma":
    let (output, code) = checkFixture("router_dtor_wrong_shape")
    check code != 0
    check output.contains("routerrejBad")
    check output.contains("`.ffi.`")

  test "{.ffiEvent.} on a static shape names the proc and the right pragma":
    let (output, code) = checkFixture("router_event_wrong_shape")
    check code != 0
    check output.contains("routerrejBad")
    check output.contains("`.ffiStatic.`")
