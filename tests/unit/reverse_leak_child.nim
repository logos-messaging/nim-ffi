## Runs a test that leaks a reverse worker on purpose in a child of the test binary,
## so the TSan thread-leak suppression covers that child only, never the suite.

import std/[os, osproc, strtabs, strutils]
import unittest2

const
  LeakChildEnv = "NIM_FFI_REVERSE_LEAK_CHILD"
  baseSupp = currentSourcePath().parentDir() / ".." / ".." / "tsan.supp"
  leakSupp = "thread:*startReverseWorkers*"

proc runLeakChild*(filter: string): tuple[output: string, exitCode: int] =
  ## Re-runs `filter` (a unittest2 `suite::test` name) with the leak suppressed.
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env[LeakChildEnv] = "1"
  let supp = getTempDir() / ("nim_ffi_reverse_leak_" & $getCurrentProcessId() & ".supp")
  writeFile(supp, readFile(baseSupp) & "\n" & leakSupp & "\n")
  var opts: seq[string] = @[]
  for part in env.getOrDefault("TSAN_OPTIONS").split(':'):
    if part.len > 0 and not part.startsWith("suppressions="):
      opts.add(part)
  opts.add("suppressions=" & supp)
  env["TSAN_OPTIONS"] = opts.join(":")
  return execCmdEx(quoteShell(getAppFilename()) & " " & quoteShell(filter), env = env)

proc ranExactlyOneTest*(output: string): bool =
  return "1 tests run" in output

template leakingTest*(suiteName, name: static string, body: untyped) =
  ## A `test` whose body leaks a worker: it runs in a child, and passes with it.
  test name:
    if existsEnv(LeakChildEnv):
      body
    else:
      let (output, code) = runLeakChild(suiteName & "::" & name)
      checkpoint(output)
      check code == 0
      check ranExactlyOneTest(output) # a renamed test would otherwise match nothing
