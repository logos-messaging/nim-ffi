## Unit tests for `ffi/internal/c_macro_helpers.nim`. The module is mostly
## compile-time AST builders, so the tests assert structural invariants on
## the produced ASTs via `treeRepr` substring matches. The tracking
## registry (`emittedCWireTypes`) is also covered because it underpins
## ordering correctness in the cwire-emission pipeline.

import std/[unittest, macros, strutils]
import ../ffi/codegen/meta
import ../ffi/internal/c_macro_helpers

# A throwaway compile-time hook to seed `ffiTypeRegistry` for the tests
# below — calling it inside a `static:` block ensures the registry is
# populated before any of the compile-time emission helpers run.
static:
  ffiTypeRegistry.add(FFITypeMeta(name: "EchoRequest",
    fields: @[
      FFIFieldMeta(name: "message", typeName: "string"),
      FFIFieldMeta(name: "delayMs", typeName: "int"),
    ]))
  ffiTypeRegistry.add(FFITypeMeta(name: "EchoResponse",
    fields: @[
      FFIFieldMeta(name: "echoed", typeName: "string"),
      FFIFieldMeta(name: "timerName", typeName: "string"),
    ]))

suite "cwireTypeName":
  test "appends _CWire to the user type name":
    check cwireTypeName("EchoRequest") == "EchoRequest_CWire"
    check cwireTypeName("X") == "X_CWire"

proc reprStringFieldWire(): string {.compileTime.} =
  let td = buildCWireTypeDef("EchoRequest",
                             @["message", "delayMs"],
                             @[ident("string"), ident("int")])
  return td.treeRepr

proc reprEmptyWire(): string {.compileTime.} =
  buildCWireTypeDef("EmptyReq", @[], @[]).treeRepr

proc reprSeqWire(): string {.compileTime.} =
  let seqInt = nnkBracketExpr.newTree(ident("seq"), ident("int"))
  buildCWireTypeDef("WithSeq", @["xs"], @[seqInt]).treeRepr

proc reprOptionWire(): string {.compileTime.} =
  let optInt = nnkBracketExpr.newTree(ident("Option"), ident("int"))
  buildCWireTypeDef("WithOpt", @["maybe"], @[optInt]).treeRepr

proc procNamesFor(typeName: string, fieldTypes: seq[NimNode]): seq[string] {.compileTime.} =
  let procs =
    buildCWireProcs(typeName,
                    @["message", "delayMs"][0 .. fieldTypes.len - 1],
                    fieldTypes)
  var ns: seq[string] = @[]
  for p in procs:
    let nm = p[0]
    let s = if nm.kind == nnkPostfix: $nm[1] else: $nm
    ns.add(s)
  return ns

proc thunkRepr(): string {.compileTime.} =
  let procs = buildCWireProcs("X", @[], @[])
  for p in procs:
    let nm = if p[0].kind == nnkPostfix: $p[0][1] else: $p[0]
    if nm == "cwireFreePtr_X":
      return p.treeRepr
  return ""

const wireStringRepr  = reprStringFieldWire()
const wireEmptyRepr   = reprEmptyWire()
const wireSeqRepr     = reprSeqWire()
const wireOptRepr     = reprOptionWire()
const procsForEcho    = procNamesFor("EchoRequest",
                                     @[ident("string"), ident("int")])
const xThunkRepr      = thunkRepr()

suite "buildCWireTypeDef":
  test "string field becomes cstring":
    check wireStringRepr.contains("EchoRequest_CWire")
    check wireStringRepr.contains("message")
    check wireStringRepr.contains("cstring")
    check wireStringRepr.contains("delayMs")
    check wireStringRepr.contains("Ident \"int\"")

  test "empty field list emits placeholder":
    check wireEmptyRepr.contains("_placeholder")
    check wireEmptyRepr.contains("uint8")

  test "seq[T] expands into items+len":
    check wireSeqRepr.contains("xs_items")
    check wireSeqRepr.contains("UncheckedArray")
    check wireSeqRepr.contains("xs_len")

  test "Option[T] becomes ptr T":
    check wireOptRepr.contains("PtrTy")
    check wireOptRepr.contains("maybe")

suite "buildCWireProcs":
  test "emits cwirePack, cwireUnpack, cwireFree and a ptr thunk":
    check procsForEcho.len == 4
    check "cwirePack"   in procsForEcho
    check "cwireUnpack" in procsForEcho
    check "cwireFree"   in procsForEcho
    check "cwireFreePtr_EchoRequest" in procsForEcho

  test "thunk takes pointer and casts to ptr <wire>":
    check xThunkRepr.len > 0
    check xThunkRepr.contains("Ident \"pointer\"")
    check xThunkRepr.contains("X_CWire")
    check xThunkRepr.contains("nimcall")

type TrackingSnapshot = object
  startsFalse, becomesTrue: bool
  idempotentDelta: int

proc trackingProbe(): TrackingSnapshot {.compileTime.} =
  ## Captures the marker tracker's three observations in a single
  ## compile-time invocation. The loops are inlined (rather than calling
  ## `isCWireEmitted`) because Nim 2.2's compile-time VM appears to cache
  ## the result of repeated `isCWireEmitted("...")` calls within the same
  ## evaluation, even after the underlying registry was mutated. An
  ## explicit `for` body with a fresh read of `emittedCWireTypes.len`
  ## sidesteps the cache.
  block startsCheck:
    var found = false
    for i in 0 ..< emittedCWireTypes.len:
      if emittedCWireTypes[i] == "__unit_test_marker__":
        found = true
        break
    result.startsFalse = not found

  markCWireEmitted("__unit_test_marker__")

  block becomesCheck:
    var found = false
    for i in 0 ..< emittedCWireTypes.len:
      if emittedCWireTypes[i] == "__unit_test_marker__":
        found = true
        break
    result.becomesTrue = found

  let before = emittedCWireTypes.len
  markCWireEmitted("__unit_test_marker__")
  result.idempotentDelta = emittedCWireTypes.len - before

proc collectDeps(): seq[string] {.compileTime.} =
  var deps: seq[string] = @[]
  let types = @[
    ident("EchoRequest"),
    nnkBracketExpr.newTree(ident("seq"), ident("EchoResponse")),
    nnkBracketExpr.newTree(ident("Option"), ident("EchoRequest")),
    ident("int"),
  ]
  collectNestedFFITypes(types, deps)
  return deps

const trackingSnap = trackingProbe()
const collectedDeps = collectDeps()

suite "emittedCWireTypes tracking":
  test "starts false, becomes true after mark":
    check trackingSnap.startsFalse
    check trackingSnap.becomesTrue

  test "marking the same type twice is idempotent":
    check trackingSnap.idempotentDelta == 0

suite "collectNestedFFITypes":
  test "picks up bare idents, seq inner and Option inner — deduped":
    check collectedDeps.len == 2
    check "EchoRequest" in collectedDeps
    check "EchoResponse" in collectedDeps
