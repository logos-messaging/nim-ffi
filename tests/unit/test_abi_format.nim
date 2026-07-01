## ABI-format annotation mechanism (issue #78): inherited default + per-spec
## override, recorded on the registry. `static:` blocks assert the registry at
## compile time; the parsing helpers run at runtime with unittest2.

import std/strutils
import unittest2
import results
import ffi
import ffi/codegen/meta

type AbiLib = object

# Stub the dylib NimMain importc that declareLibrary emits (links as a plain exe).
{.emit: "void libabitestNimMain(void) {}".}

declareLibrary("abitest", AbiLib, defaultABIFormat = "cbor")

# declareLibrary must wire its parameter into the library-wide default.
static:
  doAssert currentDefaultABIFormat == ABIFormat.Cbor

type AbiConfig {.ffi.} = object
  v: int

type Pinged {.ffi.} = object
  n: int

# Plain annotations inherit the library default (cbor).
proc abitest_create*(c: AbiConfig): Future[Result[AbiLib, string]] {.ffiCtor.} =
  return ok(AbiLib())

proc abitest_ping*(lib: AbiLib): Future[Result[string, string]] {.ffi.} =
  return ok("pong")

# Explicit override — same value, but exercises the spec parser end-to-end.
proc abitest_echo*(
    lib: AbiLib, n: int
): Future[Result[int, string]] {.ffi: "abi = cbor".} =
  return ok(n)

# Event with an explicit ABI override passed after the wire name.
proc abitest_pinged*(p: Pinged) {.ffiEvent("on_pinged", "abi = cbor").}

# Handles accept the spec for surface parity; the wire form stays uint64.
type PlainHandle {.ffiHandle.} = ref object
  v: int

type AbiHandle {.ffiHandle: "abi = cbor".} = ref object
  v: int

# Both the inherited-default and the explicit-override annotations must record
# the resolved format on their registry entries.
static:
  for name in ["abitest_create", "abitest_ping", "abitest_echo"]:
    var found = false
    for p in ffiProcRegistry:
      if p.procName == name:
        doAssert p.abiFormat == ABIFormat.Cbor, name & ": unexpected abiFormat"
        found = true
    doAssert found, "proc not registered: " & name

  block:
    var found = false
    for e in ffiEventRegistry:
      if e.wireName == "on_pinged":
        doAssert e.abiFormat == ABIFormat.Cbor, "event: unexpected abiFormat"
        found = true
    doAssert found, "event not registered: on_pinged"

suite "ABI format parsing":
  test "parseABIFormatName maps both formats, case-insensitive and trimmed":
    check parseABIFormatName("cbor") == (true, ABIFormat.Cbor)
    check parseABIFormatName("c") == (true, ABIFormat.C)
    check parseABIFormatName("CBOR") == (true, ABIFormat.Cbor)
    check parseABIFormatName("  C  ") == (true, ABIFormat.C)
    check parseABIFormatName("bson").ok == false

  test "parseAbiSpec accepts `abi = <fmt>` for both formats, flexible spacing":
    check parseAbiSpec("abi = c").fmt == ABIFormat.C
    check parseAbiSpec("abi = cbor").fmt == ABIFormat.Cbor
    check parseAbiSpec("abi=cbor").fmt == ABIFormat.Cbor
    check parseAbiSpec("ABI = C").fmt == ABIFormat.C
    check parseAbiSpec("  abi  =  cbor ").fmt == ABIFormat.Cbor
    check parseAbiSpec("abi = c").ok
    check parseAbiSpec("abi = cbor").ok

  test "parseAbiSpec rejects malformed specs and unknown formats":
    check parseAbiSpec("c").ok == false # missing `abi =`
    check parseAbiSpec("mode = c").ok == false # wrong key
    check parseAbiSpec("abi = c = x").ok == false # too many `=`
    check parseAbiSpec("abi = bson").ok == false # unknown format
    check "bson" in parseAbiSpec("abi = bson").err

suite "ABI proc-dispatch readiness":
  test "both cbor and c proc-dispatch are wired":
    # This predicate is what the proc-form macros consult. Both ABIs now have a
    # working dispatch path: `cbor` rides the generic overloads, `c` rides the
    # flat `_CWire` companions (a CBOR-free foreign surface, CBOR transport
    # internally). Events are the one `c` gap, gated separately in the macro.
    check abiCodegenImplemented(ABIFormat.Cbor)
    check abiCodegenImplemented(ABIFormat.C)
