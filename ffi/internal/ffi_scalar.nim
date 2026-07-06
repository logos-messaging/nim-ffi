## CBOR-free scalar fast path for all-scalar `{.ffi: "abi = c".}` methods.
##
## Kept out of the base `ffi` macro so the usual CBOR/async dispatch path in
## `ffi_macro.nim` stays simple: the macro only decides eligibility
## (`isScalarOnly`) and, when it applies, hands the whole codegen to
## `buildScalarPath`.
##
## A scalar proc's C export takes its scalar args directly (no
## `reqCbor`/`reqCborLen`), packs them inline into the request (no envelope
## `c_malloc`, no CBOR), and the FFI-thread handler unpacks them, runs the user
## body, and returns the result as raw bytes (`ffiScalarRetBytes`).

import std/macros
import ../codegen/meta

const scalarPodTypeNames = [
  "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
  "uint64", "byte", "float", "float32", "float64", "bool",
]
  ## Fixed-width POD scalars that fit a single `uint64` slot and survive the
  ## async hop by value — the payload the scalar fast path inlines into the
  ## request (no heap copy). `cstring`/`string` are intentionally absent as
  ## *params*: they are pointers to caller memory the FFI thread reads later,
  ## so they'd need a copy, defeating the zero-alloc promise.

func isScalarParamTypeName*(name: string): bool =
  ## A param type eligible for the CBOR-free scalar fast path.
  name in scalarPodTypeNames

func isScalarReturnTypeName*(name: string): bool =
  ## A return type eligible for the scalar fast path. Unlike params, a
  ## `string`/`cstring` return is fine: the handler produces the bytes and they
  ## ride back raw (like the error path), so no caller memory is aliased.
  name in scalarPodTypeNames or name == "string" or name == "cstring"

func isScalarOnly*(p: FFIProcMeta): bool =
  ## True iff `p` is a plain `{.ffi.}` method whose every wire param and return
  ## is scalar — the whole signature crosses without CBOR or `_CWire`. Handles
  ## and raw pointers are excluded (a handle needs a ctx-registry round-trip;
  ## a pointer never crosses). Pure over the compile-time metadata.
  if p.kind != FFIKind.FFI:
    return false
  if p.returnIsPtr or p.returnIsHandle:
    return false
  if not isScalarReturnTypeName(p.returnTypeName):
    return false
  for ep in p.extraParams:
    if ep.isPtr or ep.isHandle or not isScalarParamTypeName(ep.typeName):
      return false
  true

func bindableProcs*(procs: seq[FFIProcMeta]): seq[FFIProcMeta] =
  ## The procs the foreign-binding generators emit for. Scalar-fast-path procs
  ## are dropped: their C export takes inline scalar args, not the CBOR
  ## `(reqCbor, reqCborLen)` shape the current codegen assumes, so emitting a
  ## CBOR caller for them would be wrong. Foreign codegen is a follow-up.
  var kept: seq[FFIProcMeta] = @[]
  for p in procs:
    if not p.scalarFastPath:
      kept.add(p)
  kept

proc buildScalarPath*(
    helperProc, ctxGuard, reqPtrIdent, sendAndReply: NimNode,
    userProcName, cExportProcName: NimNode,
    cExportName: string,
    ctxType: NimNode,
    camelName: string,
    extraParamNames: seq[string],
    extraParamTypes: seq[NimNode],
    procMeta: FFIProcMeta,
): NimNode {.compileTime.} =
  ## Emits the scalar-fast-path codegen for one `.ffi.` proc. The generic
  ## dispatch pieces (`helperProc`, `ctxGuard`, `sendAndReply`) are built by the
  ## caller from the same shared helpers the usual path uses, so this only owns
  ## the scalar-specific inline pack / unpack / raw-bytes wiring.
  let scalarReqKey = camelName & "Req"

  let reqIdent = genSym(nskLet, "ffiReq")
  let ctxHandlerName = genSym(nskLet, "ffiCtxHandler")
  let handlerBody = newStmtList()
  handlerBody.add quote do:
    let `reqIdent` = cast[ptr FFIThreadRequest](request)
    let `ctxHandlerName` = cast[`ctxType`](reqHandler)

  let helperCall = newTree(nnkCall, userProcName)
  let ctxMyLib = newDotExpr(newTree(nnkDerefExpr, ctxHandlerName), ident("myLib"))
  helperCall.add(newTree(nnkDerefExpr, ctxMyLib))
  for i in 0 ..< extraParamNames.len:
    let argIdent = ident(extraParamNames[i])
    let slot = nnkBracketExpr.newTree(
      newDotExpr(newTree(nnkDerefExpr, reqIdent), ident("scalarArgs")), newLit(i)
    )
    handlerBody.add(
      newLetStmt(argIdent, newCall(ident("ffiUnpackScalar"), slot, extraParamTypes[i]))
    )
    helperCall.add(argIdent)

  let retValIdent = genSym(nskLet, "retVal")
  handlerBody.add quote do:
    let `retValIdent` = (await `helperCall`).valueOr:
      return err($error)
    return ok(ffiScalarRetBytes(`retValIdent`))

  let seqByteResult = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(
      ident("Result"),
      nnkBracketExpr.newTree(ident("seq"), ident("byte")),
      ident("string"),
    ),
  )
  let handlerProc = newProc(
    name = newEmptyNode(),
    params = @[
      seqByteResult,
      newIdentDefs(ident("request"), ident("pointer")),
      newIdentDefs(ident("reqHandler"), ident("pointer")),
    ],
    body = handlerBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )
  let registerAssign = newAssignment(
    nnkBracketExpr.newTree(ident("registeredRequests"), newLit(scalarReqKey)),
    handlerProc,
  )

  var scalarParams = @[
    ident("cint"),
    newIdentDefs(ident("ctx"), ctxType),
    newIdentDefs(ident("callback"), ident("FFICallBack")),
    newIdentDefs(ident("userData"), ident("pointer")),
  ]
  for i in 0 ..< extraParamNames.len:
    scalarParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))

  let ffiBody = newStmtList()
  ffiBody.add ctxGuard

  let initScalarCall = newTree(
    nnkCall,
    newDotExpr(ident("FFIThreadRequest"), ident("initScalar")),
    ident("callback"),
    ident("userData"),
    newDotExpr(newLit(scalarReqKey), ident("cstring")),
  )
  for i in 0 ..< extraParamNames.len:
    initScalarCall.add(newCall(ident("ffiPackScalar"), ident(extraParamNames[i])))

  ffiBody.add newLetStmt(reqPtrIdent, initScalarCall)
  ffiBody.add sendAndReply

  let ffiProc = newProc(
    name = postfix(cExportProcName, "*"),
    params = scalarParams,
    body = ffiBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  # Registered (not just skipped) so the compile-time metadata stays
  # introspectable; `bindableProcs` drops it from foreign codegen.
  var scalarMeta = procMeta
  scalarMeta.scalarFastPath = true
  ffiProcRegistry.add(scalarMeta)

  newStmtList(helperProc, registerAssign, ffiProc)
