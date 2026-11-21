## A polled message names its event or reverse call by `nameId` alone, so two
## names of one library must never share an id: the build stops instead.
## The clash fixtures compile in a child `nim check`, so a failure is an assertion;
## a real FNV-1a 64 collision cannot be written down, so each forges one.

import std/strutils
import unittest2
import ffi/codegen/meta
import ./fixture_gen

macro claim(wireName: static string, kind: static FFINameKind) =
  claimNameId(wireName, kind)

static:
  claimNameId("held_event", nkEvent)

suite "name ids are claimed once per library and kind":
  test "the same name again is accepted":
    check compiles(claim("held_event", nkEvent))

  test "a name with an id of its own is accepted":
    check compiles(claim("another_event", nkEvent))

  test "a reverse call may reuse an event's name":
    check compiles(claim("held_event", nkReverseCall))

suite "a clash stops the build":
  test "two events":
    let (output, code) = checkFixture("name_id_clash_event_fixture")
    check code != 0
    check output.contains("hash to the same name id")

  test "two reverse calls":
    let (output, code) =
      checkFixture("name_id_clash_reverse_fixture", ["-d:ffiPollMode"])
    check code != 0
    check output.contains("hash to the same name id")

  test "an event dispatched by a literal name":
    let (output, code) = checkFixture("name_id_clash_dispatch_fixture")
    check code != 0
    check output.contains("hash to the same name id")
