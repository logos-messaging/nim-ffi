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

# Per-proc handler-timeout override (issue #93): parsed like the abi spec and
# recorded in `requestTimeoutsMs`, keyed by the generated Req type name.
proc abitest_slow*(
    lib: AbiLib, n: int
): Future[Result[int, string]] {.ffi: "timeout = 30000".} =
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

suite "handler-timeout spec parsing (issue #93)":
  test "overrideKey extracts the lowercased, trimmed key":
    check overrideKey("timeout = 30000") == "timeout"
    check overrideKey("  ABI = c ") == "abi"
    check overrideKey("bare") == "bare"

  test "parseTimeoutSpec accepts `timeout = <ms>`, flexible spacing":
    check parseTimeoutSpec("timeout = 30000") == (true, 30000, "")
    check parseTimeoutSpec("TIMEOUT=100").ms == 100
    check parseTimeoutSpec("  timeout  =  5 ").ms == 5

  test "parseTimeoutSpec rejects malformed specs and non-positive values":
    check parseTimeoutSpec("30000").ok == false # missing `timeout =`
    check parseTimeoutSpec("abi = c").ok == false # wrong key
    check parseTimeoutSpec("timeout = 1 = 2").ok == false # too many `=`
    check parseTimeoutSpec("timeout = abc").ok == false # not an integer
    check parseTimeoutSpec("timeout = 0").ok == false # must be positive
    check parseTimeoutSpec("timeout = -5").ok == false # must be positive

  test "a `timeout` override is recorded; a plain proc has no entry":
    # Populated at module init from the annotations above.
    check requestTimeoutsMs["AbitestSlowReq".cstring] == 30000
    check not requestTimeoutsMs.hasKey("AbitestPingReq".cstring)

suite "ABI proc-dispatch readiness (why c is still gated on procs)":
  test "cbor proc-dispatch is wired; c proc-dispatch is gated":
    # This predicate is what the proc-form macros consult: `cbor` is wired
    # end-to-end, while `c` is recognized but gated pending its codec. It is the
    # single seam a future PR flips when the c codec and dispatch path land.
    check abiCodegenImplemented(ABIFormat.Cbor)
    check not abiCodegenImplemented(ABIFormat.C)
