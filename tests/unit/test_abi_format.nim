## ABI-format annotation: inherited default + per-spec override, recorded on the registry.

import std/strutils
import unittest2
import results
import ffi
import ffi/codegen/meta

type AbiLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libabitestNimMain(void) {}".}

declareLibrary("abitest", AbiLib, defaultABIFormat = "cbor")

static:
  doAssert currentDefaultABIFormat == ABIFormat.Cbor

type AbiConfig {.ffi.} = object
  v: int

type Pinged {.ffi.} = object
  n: int

# Plain annotations inherit the library default.
proc abitest_create*(c: AbiConfig): Future[Result[AbiLib, string]] {.ffiCtor.} =
  return ok(AbiLib())

proc abitest_ping*(lib: AbiLib): Future[Result[string, string]] {.ffi.} =
  return ok("pong")

# Explicit override exercises the spec parser.
proc abitest_echo*(
    lib: AbiLib, n: int
): Future[Result[int, string]] {.ffi: "abi = cbor".} =
  return ok(n)

proc abitest_pinged*(p: Pinged) {.ffiEvent("on_pinged", "abi = cbor").}

type PlainHandle {.ffiHandle.} = ref object
  v: int

type AbiHandle {.ffiHandle: "abi = cbor".} = ref object
  v: int

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

suite "pragma override key parsing":
  test "overrideKey extracts the lowercased, trimmed key":
    check overrideKey("abi = c") == "abi"
    check overrideKey("  ABI = c ") == "abi"
    check overrideKey("bare") == "bare"

suite "ABI proc-dispatch readiness":
  test "both cbor and c proc-dispatch are wired":
    check abiCodegenImplemented(ABIFormat.Cbor)
    check abiCodegenImplemented(ABIFormat.C)
