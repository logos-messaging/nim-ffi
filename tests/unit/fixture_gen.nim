## Drives the compile fixtures under `fixtures/` through a child compiler, so a
## fixture's success or failure becomes an assertion instead of this suite's own
## compile error.

import std/[os, osproc, strutils, compilesettings]

const
  nimExe = getCurrentCompilerExe()
  ffiSearchPaths = querySettingSeq(searchPaths)
  fixtureDir = currentSourcePath().parentDir() / "fixtures"

func compilerCmd(subCmd, fixture, cacheTag: string): string =
  var cmd = quoteShell(nimExe) & " " & subCmd & " --hints:off --warnings:off"
  for p in ffiSearchPaths:
    cmd.add(" --path:" & quoteShell(p))
  cmd.add(" --nimcache:" & quoteShell(getTempDir() / ("ffi_fixture_cache_" & cacheTag)))
  return cmd

proc genFixtureBindings*(
    fixture, lang: string, extraDefs: openArray[string] = []
): tuple[outDir: string, output: string, exitCode: int] =
  ## Generates `lang` bindings for `fixtures/<fixture>.nim`. The output dir is
  ## wiped first, so a stale artifact from an earlier run can't satisfy an
  ## assertion the current generator would have failed.
  let tag = fixture & "_" & lang
  let outDir = getTempDir() / ("ffi_fixture_out_" & tag)
  removeDir(outDir)
  createDir(outDir)
  var cmd = compilerCmd("c --compileOnly", fixture, tag)
  cmd.add(" -d:ffiGenBindings -d:targetLang=" & lang)
  cmd.add(" -d:ffiOutputDir=" & quoteShell(outDir))
  for d in extraDefs:
    cmd.add(" " & d)
  cmd.add(" " & quoteShell(fixtureDir / (fixture & ".nim")))
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo output
  return (outDir, output, code)

proc checkFixture*(
    fixture: string, extraDefs: openArray[string] = []
): tuple[output: string, exitCode: int] =
  ## `nim check` of a fixture expected to fail, so its error is a test assertion.
  var cmd = compilerCmd("check", fixture, fixture & "_check")
  for d in extraDefs:
    cmd.add(" " & d)
  cmd.add(" " & quoteShell(fixtureDir / (fixture & ".nim")))
  return execCmdEx(cmd)
