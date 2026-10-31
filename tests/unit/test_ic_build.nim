## `--ic:on` compiles each module in its own process; the fixture spans three modules.

import std/[os, strutils]
import unittest2
import ./fixture_gen

template skipIfNoNifler(output: string, code: int, body: untyped) =
  if code != 0 and "nifler failed" in output:
    skip() # The prebuilt linux_x64 Nim 2.4.0 ships a musl nifler.
  else:
    body

when (NimMajor, NimMinor) >= (2, 4):
  suite "--ic:on over several modules":
    test "the annotations see declareLibrary and genBindings sees the annotations":
      let (outDir, output, code) = genFixtureBindings("ic_fixture", "c", ["--ic:on"])
      skipIfNoNifler(output, code):
        check code == 0
        let header = readFile(outDir / "icfixture.h")
        for name in [
          "icfixture_create", "icfixture_reply", "IC_LIMIT", "IcReply", "on_reply",
          "IcFixtureOpenReplyFn)(int err_code, const uint64_t* reply",
        ]:
          check name in header
        check "ic_fixture.nim" in readFile(outDir / "CMakeLists.txt")

    test "the default output dir is c_bindings next to the compiled file":
      let defaultDir = currentSourcePath().parentDir() / "fixtures" / "c_bindings"
      let (_, output, code) =
        genFixtureBindings("ic_fixture", "c", ["--ic:on", "-d:ffiOutputDir="])
      skipIfNoNifler(output, code):
        defer:
          removeDir(defaultDir)
        check code == 0
        check fileExists(defaultDir / "icfixture.h")

    for (fixture, message) in [
      ("ic_fixture_late", "must be called from the compilation root"),
      ("ic_fixture_nodecl", "declareLibrary(name, LibType) must be called"),
    ]:
      test fixture & " is rejected with its diagnostic":
        let (_, output, code) = genFixtureBindings(fixture, "c", ["--ic:on"])
        skipIfNoNifler(output, code):
          check code != 0
          check message in output
