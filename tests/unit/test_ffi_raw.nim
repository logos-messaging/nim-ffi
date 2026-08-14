## `{.ffiRaw.}` has no user left in the tree, so its expansion is compiled here.

import unittest2
import ./fixture_gen

suite "{.ffiRaw.} entry point":
  test "the raw proc expands into an entry point that compiles":
    let genned = genFixtureBindings("ffiraw_fixture", "c")
    check genned.exitCode == 0
