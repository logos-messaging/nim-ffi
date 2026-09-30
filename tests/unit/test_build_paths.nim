## Codegen path helpers answer for the BUILD OS, not the target: the compiler
## writes these files and the build systems that carry them run here.
import unittest2
from system/nimscript import buildOS
import ffi/codegen/build_paths

suite "codegen build paths":
  test "buildPath joins with one build separator":
    check buildPath("out", "gen") ==
      (when buildOS == "windows": "out\\gen" else: "out/gen")
    check buildPath("out/", "/gen") ==
      (when buildOS == "windows": "out/gen" else: "out/gen")
    check buildPath("", "gen") == "gen"
    check buildPath("out", "") == "out"

  test "buildIsAbsolute follows the build OS":
    when buildOS == "windows":
      check buildIsAbsolute("C:\\src")
      check buildIsAbsolute("\\src")
    else:
      check buildIsAbsolute("/src")
      check not buildIsAbsolute("C:\\src")
    check not buildIsAbsolute("src")
    check not buildIsAbsolute("")

  test "buildRelativePath walks up without consulting the cwd":
    when buildOS == "windows":
      check buildRelativePath("C:\\a\\b\\lib.nim", "C:\\a\\b\\out") == "..\\lib.nim"
      check buildRelativePath("C:\\a\\lib.nim", "C:\\a") == "lib.nim"
      check buildRelativePath("C:\\a", "C:\\a") == "."
    else:
      check buildRelativePath("/a/b/lib.nim", "/a/b/out") == "../lib.nim"
      check buildRelativePath("/a/lib.nim", "/a") == "lib.nim"
      check buildRelativePath("/a", "/a") == "."

  test "buildRelativePath leaves a non-absolute argument alone":
    check buildRelativePath("lib.nim", "/a/out") == "lib.nim"
    check buildRelativePath("/a/lib.nim", "out") == "/a/lib.nim"
