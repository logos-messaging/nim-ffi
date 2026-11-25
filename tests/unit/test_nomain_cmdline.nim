import std/[compilesettings, os, osproc]
import unittest2

when defined(linux):
  const
    nimExe = getCurrentCompilerExe()
    searchPaths = querySettingSeq(SingleValueSeqSetting.searchPaths)
    fixtureDir = currentSourcePath().parentDir() / "fixtures"

  suite "--noMain command-line symbols":
    test "a whole static archive links and uses the host's arguments":
      let tempDir = getTempDir() / "ffi_nomain_cmdline"
      removeDir(tempDir)
      createDir(tempDir)
      defer:
        removeDir(tempDir)

      let archive = tempDir / "libcmdlinefixture.a"
      let host = tempDir / "host"
      var cmd = quoteShell(nimExe) &
        " c --hints:off --mm:orc --app:staticlib --noMain" &
        " --nimMainPrefix:libcmdlinefixture --nimcache:" & quoteShell(tempDir / "cache") &
        " -o:" & quoteShell(archive)
      for path in searchPaths:
        cmd.add(" --path:" & quoteShell(path))
      cmd.add(" " & quoteShell(fixtureDir / "nomain_cmdline_fixture.nim"))
      let (buildOutput, buildCode) = execCmdEx(cmd)
      checkpoint buildOutput
      require buildCode == 0

      let (linkOutput, linkCode) = execCmdEx(
        "cc -o " & quoteShell(host) & " " &
          quoteShell(fixtureDir / "nomain_cmdline_host.c") &
          " -Wl,--whole-archive " & quoteShell(archive) &
          " -Wl,--no-whole-archive -pthread -lm -ldl -lrt"
      )
      checkpoint linkOutput
      require linkCode == 0
      let (output, code) = execCmdEx(quoteShell(host))
      checkpoint output
      check code == 0

    test "an ordinary executable still supplies its own symbols":
      let tempDir = getTempDir() / "ffi_main_cmdline"
      removeDir(tempDir)
      createDir(tempDir)
      defer:
        removeDir(tempDir)
      var cmd = quoteShell(nimExe) &
        " c -r --hints:off --nimMainPrefix:libcmdlinefixture" &
        " --nimcache:" & quoteShell(tempDir / "cache") &
        " -o:" & quoteShell(tempDir / "fixture")
      for path in searchPaths:
        cmd.add(" --path:" & quoteShell(path))
      cmd.add(" " & quoteShell(fixtureDir / "nomain_cmdline_fixture.nim"))
      let (output, code) = execCmdEx(cmd)
      checkpoint output
      check code == 0
