## host/nim_ffi_host.hpp against a scripted fake library (tests/host/): the pump's
## ordering, deadlines, late replies, reverse calls and closing, without Nim in the loop.

import std/[os, osproc, strutils]
import unittest2

const
  repoDir = currentSourcePath().parentDir().parentDir().parentDir()
  source = repoDir / "tests" / "host" / "test_nim_ffi_host.cpp"

suite "nim_ffi::Host (C++)":
  test "the pump behaves against a scripted library":
    let exe = getTempDir() / "nim_ffi_host_test"
    let (build, buildCode) = execCmdEx(
      "c++ -std=c++17 -Wall -Wextra -pthread -o " & quoteShell(exe) & " " &
        quoteShell(source)
    )
    check buildCode == 0
    if buildCode != 0:
      echo build
    let (output, code) = execCmdEx(quoteShell(exe))
    check code == 0
    check output.contains("ok")
    if code != 0:
      echo output
