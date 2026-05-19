## Unit-tests for the CDDL schema generator. Drives it directly against a
## synthetic `ffiProcRegistry` / `ffiTypeRegistry` so we don't need to invoke
## the macro pipeline (and thus don't write any files).

import std/strutils
import unittest2
import ../ffi/codegen/[meta, cddl]

proc fieldsOf(pairs: openArray[(string, string)]): seq[FFIFieldMeta] =
  var res: seq[FFIFieldMeta] = @[]
  for p in pairs:
    res.add(FFIFieldMeta(name: p[0], typeName: p[1]))
  return res

proc paramsOf(triples: openArray[(string, string, bool)]): seq[FFIParamMeta] =
  var res: seq[FFIParamMeta] = @[]
  for t in triples:
    res.add(FFIParamMeta(name: t[0], typeName: t[1], isPtr: t[2]))
  return res

proc field(n, t: string): FFIFieldMeta =
  FFIFieldMeta(name: n, typeName: t)

proc param(n, t: string, isPtr = false): FFIParamMeta =
  FFIParamMeta(name: n, typeName: t, isPtr: isPtr)

suite "nimTypeToCddl primitive mapping":
  test "primitives map to CDDL builtins":
    check nimTypeToCddl("bool") == "bool"
    check nimTypeToCddl("int") == "int"
    check nimTypeToCddl("int32") == "int"
    check nimTypeToCddl("uint64") == "uint"
    check nimTypeToCddl("float64") == "float64"
    check nimTypeToCddl("string") == "tstr"
    check nimTypeToCddl("cstring") == "tstr"
    check nimTypeToCddl("pointer") == "uint"

  test "pointer types map to uint":
    check nimTypeToCddl("ptr Foo") == "uint"

  test "seq[T] becomes [* T]":
    check nimTypeToCddl("seq[int]") == "[* int]"
    check nimTypeToCddl("seq[string]") == "[* tstr]"

  test "Option[T] becomes T / nil":
    check nimTypeToCddl("Option[int]") == "int / nil"
    check nimTypeToCddl("Maybe[string]") == "tstr / nil"

  test "nested generics":
    check nimTypeToCddl("seq[Option[int]]") == "[* int / nil]"

  test "unknown PascalCase is passed through as a rule reference":
    check nimTypeToCddl("EchoRequest") == "EchoRequest"

suite "generateCddlSchema":
  setup:
    let types = @[
      FFITypeMeta(
        name: "EchoRequest",
        fields: @[field("message", "string"), field("delayMs", "int")],
      ),
      FFITypeMeta(name: "EchoResponse", fields: @[field("echoed", "string")]),
    ]

    let procs = @[
      FFIProcMeta(
        procName: "nimtimer_create",
        libName: "nimtimer",
        kind: FFIKind.CTOR,
        libTypeName: "NimTimer",
        extraParams: @[param("config", "TimerConfig")],
        returnTypeName: "NimTimer",
        returnIsPtr: false,
      ),
      FFIProcMeta(
        procName: "nimtimer_echo",
        libName: "nimtimer",
        kind: FFIKind.FFI,
        libTypeName: "NimTimer",
        extraParams: @[param("req", "EchoRequest")],
        returnTypeName: "EchoResponse",
        returnIsPtr: false,
      ),
      FFIProcMeta(
        procName: "nimtimer_destroy",
        libName: "nimtimer",
        kind: FFIKind.DTOR,
        libTypeName: "NimTimer",
        extraParams: @[],
        returnTypeName: "",
        returnIsPtr: false,
      ),
    ]

    let cddl = generateCddlSchema(procs, types, "nimtimer", "../nim_timer.nim")

  test "header references the source file":
    check "../nim_timer.nim" in cddl
    check "CBOR (RFC 8949)" in cddl

  test "user-declared types become CDDL map rules":
    check "EchoRequest = { message: tstr, delayMs: int }" in cddl
    check "EchoResponse = { echoed: tstr }" in cddl

  test "per-proc request envelopes are emitted":
    check "NimtimerCreateCtorReq = { config: TimerConfig }" in cddl
    check "NimtimerEchoReq = { req: EchoRequest }" in cddl

  test "proc request/response rules":
    check "nimtimer_create-request = NimtimerCreateCtorReq" in cddl
    check "nimtimer_create-response = tstr" in cddl
    check "nimtimer_echo-request = NimtimerEchoReq" in cddl
    check "nimtimer_echo-response = EchoResponse" in cddl

  test "dtor has no request envelope and a nil response":
    check "nimtimer_destroy-request" notin cddl
    check "nimtimer_destroy-response = nil" in cddl

  test "kind tags appear in proc comments":
    check "; nimtimer_create (ctor)" in cddl
    check "; nimtimer_echo (ffi)" in cddl
    check "; nimtimer_destroy (dtor)" in cddl
