## Asserts the two `declareLibrary`/`genBindings` contracts that hold at macro
## time: the `ABIFormat` enum overload compiles, and an {.ffiCtor.} with no
## {.ffiDtor.} fails the build. Each fixture compiles in a child `nim check` so
## its expected result is an assertion rather than this file's own compile error.

import std/[os, osproc, strutils, compilesettings]
import unittest2

const
  fixtureDir = currentSourcePath().parentDir() / "fixtures"
  nimExe = getCurrentCompilerExe()
  ffiSearchPaths = querySettingSeq(searchPaths)

proc checkFixture(name: string): tuple[output: string, exitCode: int] =
  let cacheDir = getTempDir() / "ffi_declare_library_cache" / name
  var cmd = quoteShell(nimExe) & " check --hints:off --warnings:off"
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" --nimcache:" & quoteShell(cacheDir))
  cmd.add(" " & quoteShell(fixtureDir / (name & "_fixture.nim")))
  execCmdEx(cmd)

suite "declareLibrary accepts the ABIFormat enum overload":
  test "defaultABIFormat = ABIFormat.C compiles and sets the library default":
    let (output, code) = checkFixture("declare_enum_abi")
    check code == 0
    check not output.contains("Error")

suite "genBindings requires a dtor when a ctor is declared":
  test "an {.ffiCtor.} with no {.ffiDtor.} fails, naming the ctor and the fix":
    let (output, code) = checkFixture("ctor_without_dtor")
    check code != 0
    check output.contains("nodtor_create")
    check output.contains("ffiDtor")
