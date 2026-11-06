## Asserts the contracts that hold at macro time: an {.ffiCtor.} with no
## {.ffiDtor.} fails the build, and so do a leftover `"abi = ..."` argument and
## a bad {.ffiReverse.} timeout or wire name.
## Each fixture compiles in a child `nim check`, so its failure is an assertion.

import std/strutils
import unittest2
import ./fixture_gen

suite "genBindings requires a dtor when a ctor is declared":
  test "an {.ffiCtor.} with no {.ffiDtor.} fails, naming the ctor and the fix":
    let (output, code) = checkFixture("ctor_without_dtor_fixture")
    check code != 0
    check output.contains("nodtor_create")
    check output.contains("ffiDtor")

suite "the removed `abi = ...` argument fails loudly":
  test "an `abi = c` spec on a {.ffi.} proc names the removal":
    let (output, code) = checkFixture("abi_spec_proc_fixture")
    check code != 0
    check output.contains("takes no pragma argument")
    check output.contains("CBOR is the only wire")

  test "an `abi = cbor` spec on an {.ffiEvent.} is not taken as a wire name":
    let (output, code) = checkFixture("abi_spec_event_fixture")
    check code != 0
    check output.contains("wire name must not contain '='")

suite "{.ffiReverse.} pragma arguments are checked at macro time":
  test "a timeout of 0 ms fails the build":
    let (output, code) = checkFixture("reverse_timeout_zero_fixture")
    check code != 0
    check output.contains("`timeout` must be a positive number of ms")

  test "a wire name that is not a C identifier fails the build":
    let (output, code) = checkFixture("reverse_wire_name_fixture")
    check code != 0
    check output.contains("wire name must be a C identifier")
