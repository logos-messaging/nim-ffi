import std/[macros, tables, strutils]
import chronos
import ../ffi_types
import ../codegen/[meta, string_helpers]
when defined(ffiGenBindings):
  import ../codegen/rust
  import ../codegen/cpp
  import ../codegen/cddl
  import ../codegen/c
  import ../codegen/go

# ---------------------------------------------------------------------------
# String helpers used by multiple macros
# ---------------------------------------------------------------------------

proc isPtr(typ: NimNode): bool =
  ## True iff `typ` is a `ptr T` type expression — i.e. an `nnkPtrTy` AST node.
  ## Used by the binding-generator metadata path to flag pointer-typed params
  ## and return types so the foreign side can render them as opaque addresses.
  typ.kind == nnkPtrTy

proc rejectRawPtrType(typ: NimNode, where: string) =
  ## Errors out at macro-expansion time if `typ` is `pointer` or `ptr T`.
  ## Raw addresses must not cross the FFI boundary in user-declared fields,
  ## parameters, or return types: the only pointer that legitimately crosses
  ## the boundary is the opaque ctx handle returned by `.ffiCtor.` and passed
  ## back as the first C-ABI argument, which the framework validates via
  ## FFIContextPool.isValidCtx before dereferencing. Any other raw pointer
  ## would hand the foreign caller an address with no way to validate its
  ## memory state — see PR #23 review (discussion_r3236531712).
  ##
  ## `object` and `ref T` are not rejected: they flow as value copies through
  ## cbor_serialization (the library's default `ref T` writer dereferences
  ## and encodes the pointee, so no address crosses the boundary).
  if typ.kind == nnkPtrTy:
    error(
      where & ": raw `ptr T` is not allowed across the FFI boundary " &
        "(only the ctx handle, managed by the framework, may be a pointer)"
    )
  if typ.kind == nnkIdent and $typ == "pointer":
    error(
      where & ": raw `pointer` is not allowed across the FFI boundary " &
        "(only the ctx handle, managed by the framework, may be a pointer)"
    )

proc registerFFITypeInfo(typeDef: NimNode): NimNode {.compileTime.} =
  ## Registers the type in ffiTypeRegistry for binding generation and returns
  ## the clean typeDef. Serialization is handled by the generic overloads in
  ## cbor_serial.nim.
  let typeName =
    if typeDef[0].kind == nnkPostfix:
      typeDef[0][1]
    else:
      typeDef[0]
  let typeNameStr = $typeName

  var fieldMetas: seq[FFIFieldMeta] = @[]
  let objTy = typeDef[2]
  if objTy.kind == nnkObjectTy and objTy.len >= 3:
    let recList = objTy[2]
    if recList.kind == nnkRecList:
      for identDef in recList:
        if identDef.kind == nnkIdentDefs:
          let fieldType = identDef[^2]
          for i in 0 ..< identDef.len - 2:
            rejectRawPtrType(
              fieldType, "{.ffi.} type " & typeNameStr & "." & $identDef[i]
            )
          let fieldTypeName =
            if fieldType.kind == nnkIdent:
              $fieldType
            else:
              fieldType.repr
          for i in 0 ..< identDef.len - 2:
            fieldMetas.add(FFIFieldMeta(name: $identDef[i], typeName: fieldTypeName))

  ffiTypeRegistry.add(FFITypeMeta(name: typeNameStr, fields: fieldMetas))
  return typeDef

proc nimTypeNameRepr(typ: NimNode): string =
  ## Stringifies a parameter or field type for the binding-generator registry.
  ## `$ident` works for simple types; bracket/dot/expression types need `repr`.
  case typ.kind
  of nnkIdent:
    $typ
  of nnkPtrTy:
    "ptr " & nimTypeNameRepr(typ[0])
  else:
    typ.repr

proc storageType(typ: NimNode): NimNode =
  ## Returns the in-Req-struct storage type for a user-declared param type.
  ## `cstring` is stored as `string` for trivial CBOR transport; everything
  ## else is stored as the user typed it.
  if typ.kind == nnkIdent and $typ == "cstring":
    return ident("string")
  return typ

proc unpackReqField*(fieldIdent, userType, decodedIdent: NimNode): NimNode =
  ## Emits AST for unpacking one field from a CBOR-decoded Req struct into a
  ## local typed as the user's original param type.
  ##
  ## `cstring` params are stored as `string` in the Req (per storageType)
  ## and cast back via `.cstring` on unpack — safe because `decodedIdent`
  ## outlives the cstring use within the generated proc body.
  ##
  ## Produces one of:
  ##   let <field>: cstring = (<decoded>.<field>).cstring   # for cstring
  ##   let <field> = <decoded>.<field>                       # for everything else
  ##
  ## Built with the runtime AST API rather than `quote do:` so the proc is
  ## callable from both macro context and ordinary code (e.g. unit tests).
  let storedAsString = userType.kind == nnkIdent and $userType == "cstring"
  if not storedAsString:
    return newLetStmt(fieldIdent, newDotExpr(decodedIdent, fieldIdent))

  let fieldAccess = newDotExpr(decodedIdent, fieldIdent)
  let castExpr = newDotExpr(fieldAccess, ident("cstring"))
  return
    nnkLetSection.newTree(nnkIdentDefs.newTree(fieldIdent, ident("cstring"), castExpr))

proc cExportedParams(ctxType: NimNode): seq[NimNode] =
  ## Standard parameter list for the C-exported wrapper of a .ffi. proc:
  ##   (returns cint; ctx, callback, userData, reqCbor, reqCborLen)
  ## Shared by the async and sync paths so both wrappers carry the same ABI.
  var params: seq[NimNode] = @[]
  params.add(ident("cint"))
  params.add(newIdentDefs(ident("ctx"), ctxType))
  params.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  params.add(newIdentDefs(ident("userData"), ident("pointer")))
  params.add(newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte"))))
  params.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))
  return params

proc buildReqTypeFromFields(
    reqTypeName: NimNode, paramNames: seq[string], paramTypes: seq[NimNode]
): NimNode =
  ## Builds the per-proc Req `nnkTypeSection` (exported) from explicit
  ## parallel lists of parameter names and types. The result is the AST for
  ## a `type Foo* = object` declaration that the codegen later emits.
  ##
  ## `cstring` parameter types are rewritten to `string` (via storageType)
  ## so the request can ride a plain CBOR text string on the wire. Empty
  ## parameter lists get a single `_placeholder: uint8` field so the object
  ## type is well-formed (Nim won't accept an empty `object` body here).
  ##
  ## Examples (in pseudo-Nim, showing the AST this proc produces):
  ##
  ##   buildReqTypeFromFields(
  ##     reqTypeName = ident("EchoReq"),
  ##     paramNames  = @["message", "delayMs"],
  ##     paramTypes  = @[ident("cstring"), ident("int")])
  ##   # → type EchoReq* = object
  ##   #     message: string   # cstring rewritten to string
  ##   #     delayMs: int
  ##
  ##   buildReqTypeFromFields(
  ##     reqTypeName = ident("VersionReq"),
  ##     paramNames  = @[],
  ##     paramTypes  = @[])
  ##   # → type VersionReq* = object
  ##   #     _placeholder: uint8   # placeholder for the empty-params case
  ##
  ## If `reqTypeName` is already a postfix node (e.g. `EchoReq*`) it is used
  ## as-is; otherwise the `*` export marker is added.
  var fields: seq[NimNode] = @[]
  for i in 0 ..< paramNames.len:
    let storedType = storageType(paramTypes[i])
    fields.add newTree(nnkIdentDefs, ident(paramNames[i]), storedType, newEmptyNode())

  let recList =
    if fields.len > 0:
      newTree(nnkRecList, fields)
    else:
      newTree(
        nnkRecList,
        newTree(nnkIdentDefs, ident("_placeholder"), ident("uint8"), newEmptyNode()),
      )

  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)

  let typeName =
    if reqTypeName.kind == nnkPostfix:
      reqTypeName
    else:
      postfix(reqTypeName, "*")

  return
    newNimNode(nnkTypeSection).add(newTree(nnkTypeDef, typeName, newEmptyNode(), objTy))

proc buildRequestType(reqTypeName: NimNode, body: NimNode): NimNode =
  ## Builds the per-proc Req object type from a registerReqFFI lambda body.
  ## Field names match the lambda params; field types match the user-typed
  ## param types (with `cstring` rewritten to `string` for transport).
  ##
  ## Builds:
  ##   type <reqTypeName>* = object
  ##     <lambdaParam1Name>: <lambdaParam1Type>
  ##     ...
  ##
  ## e.g.:
  ##   type EchoRequest* = object
  ##     message: string
  ##     delayMs: int

  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda proc, found: " & $procNode.kind

  let params = procNode[3]
  var paramNames: seq[string] = @[]
  var paramTypes: seq[NimNode] = @[]
  for p in params[1 .. ^1]:
    paramNames.add($p[0])
    paramTypes.add(p[1])

  let typeSection = buildReqTypeFromFields(reqTypeName, paramNames, paramTypes)

  when defined(ffiDumpMacros):
    echo typeSection.repr
  return typeSection

proc buildFFINewReqProc(reqTypeName, body: NimNode): NimNode =
  ## Builds ffiNewReq: takes the user's typed params, packs them into a Req
  ## object, CBOR-encodes the Req into one byte buffer, and constructs the
  ## FFIThreadRequest that owns the buffer.

  var formalParams = newSeq[NimNode]()

  var procNode: NimNode
  if body.kind == nnkStmtList and body.len == 1:
    procNode = body[0]
  else:
    procNode = body

  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda definition. Found: " & $procNode.kind

  # T: typedesc[XxxReq]
  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  formalParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  # User-typed lambda params (kept as-is so callers see their original signature)
  let procParams = procNode[3]
  for p in procParams[1 .. ^1]:
    formalParams.add(p)

  let retType = newNimNode(nnkPtrTy)
  retType.add(ident("FFIThreadRequest"))

  formalParams = @[retType] & formalParams

  let reqObjIdent = ident("reqObj")
  var newBody = newStmtList()
  newBody.add(
    quote do:
      var `reqObjIdent`: T
  )

  for p in procParams[1 .. ^1]:
    let fieldName = ident($p[0])
    let userType = p[1]
    let storeAsString = userType.kind == nnkIdent and $userType == "cstring"
    if storeAsString:
      newBody.add(
        quote do:
          `reqObjIdent`.`fieldName` = $`fieldName`
      )
    else:
      newBody.add(
        quote do:
          `reqObjIdent`.`fieldName` = `fieldName`
      )

  newBody.add(
    quote do:
      let typeStr = $T
      # Encode directly into shared memory and hand ownership to the request,
      # avoiding the seq[byte] → allocShared+copyMem second copy.
      let (sharedData, sharedLen) = cborEncodeShared(`reqObjIdent`)
      return FFIThreadRequest.initFromOwnedShared(
        callback, userData, typeStr.cstring, sharedData, sharedLen
      )
  )

  let newReqProc = newProc(
    name = postfix(ident("ffiNewReq"), "*"),
    params = formalParams,
    body = newBody,
    pragmas = newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo newReqProc.repr
  return newReqProc

proc buildProcessFFIRequestProc(reqTypeName, reqHandler, body: NimNode): NimNode =
  ## Generates the FFI-thread-side processor for the Req type.
  ## Decodes the CBOR payload into a Req struct, unpacks each field into a
  ## local, then runs the user lambda body.

  if reqHandler.kind != nnkExprColonExpr:
    error(
      "Second argument must be a typed parameter, e.g., waku: ptr Waku. Found: " &
        $reqHandler.kind
    )

  let rhs = reqHandler[1]
  if rhs.kind != nnkPtrTy:
    error("Second argument must be a pointer type, e.g., waku: ptr Waku")

  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda definition. Found: " & $procNode.kind

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))

  let procParams = procNode[3]
  var formalParams: seq[NimNode] = @[]
  formalParams.add(procParams[0]) # return type
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("request"), ident("pointer")))
  formalParams.add(newIdentDefs(reqHandler[0], rhs)) # e.g. waku: ptr Waku

  let bodyNode =
    if procNode.body.kind == nnkStmtList:
      procNode.body
    else:
      newStmtList(procNode.body)

  let newBody = newStmtList()
  let reqIdent = genSym(nskLet, "ffiReq")
  let decodedIdent = genSym(nskLet, "decoded")

  newBody.add quote do:
    let `reqIdent`: ptr FFIThreadRequest = cast[ptr FFIThreadRequest](request)
    let `decodedIdent` = cborDecodePtr(
      cast[ptr UncheckedArray[byte]](`reqIdent`[].data),
      `reqIdent`[].dataLen,
      `reqTypeName`,
    ).valueOr:
      return err("CBOR decode failed for " & $T & ": " & $error)

  # Unpack each field as a local typed as the user's original param type.
  for p in procParams[1 ..^ 1]:
    newBody.add unpackReqField(p[0], p[1], decodedIdent)

  newBody.add(bodyNode)

  let processProc = newProc(
    name = postfix(ident("processFFIRequest"), "*"),
    params = formalParams,
    body = newBody,
    procType = nnkProcDef,
    pragmas =
      if procNode.len >= 5:
        procNode[4]
      else:
        newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo processProc.repr
  return processProc

proc addNewRequestToRegistry(reqTypeName, reqHandler: NimNode): NimNode =
  ## Generates the dispatcher that the FFI thread calls: it invokes
  ## processFFIRequest (which returns the user's typed Result[T, string]) and
  ## encodes a successful T value with cborEncode into the seq[byte] payload.

  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(
      ident("Result"),
      nnkBracketExpr.newTree(ident("seq"), ident("byte")),
      ident("string"),
    ),
  )

  let rhsType =
    if reqHandler.kind == nnkExprColonExpr:
      reqHandler[1]
    else:
      error "Second argument must be a typed parameter, e.g. waku: ptr Waku"

  let castedHandler = newTree(nnkCast, rhsType, ident("reqHandler"))

  let callExpr = newCall(
    newDotExpr(reqTypeName, ident("processFFIRequest")), ident("request"), castedHandler
  )

  let typedResIdent = genSym(nskLet, "typedRes")

  var newBody = newStmtList()
  newBody.add quote do:
    let `typedResIdent` = await `callExpr`
    if `typedResIdent`.isErr:
      return err(`typedResIdent`.error)
    when typeof(`typedResIdent`.value) is seq[byte]:
      return ok(`typedResIdent`.value)
    elif typeof(`typedResIdent`.value) is void:
      return ok(newSeq[byte]())
    else:
      return ok(cborEncode(`typedResIdent`.value))

  let asyncProc = newProc(
    name = newEmptyNode(),
    params = @[
      returnType,
      newIdentDefs(ident("request"), ident("pointer")),
      newIdentDefs(ident("reqHandler"), ident("pointer")),
    ],
    body = newBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )

  let key = newLit($reqTypeName)
  let regAssign =
    newAssignment(newTree(nnkBracketExpr, ident("registeredRequests"), key), asyncProc)

  when defined(ffiDumpMacros):
    echo regAssign.repr
  return regAssign

macro registerReqFFI*(reqTypeName, reqHandler, body: untyped): untyped =
  ## Registers a request that will be handled by the FFI/working thread.
  ## The request should be sent from the ffi consumer thread.
  ##
  ## The lambda passed to this macro must:
  ##   - Only have no-GC'ed types as parameters (cstring is allowed; it gets
  ##     transported as `string` in the per-proc Req struct).
  ##   - Return Future[Result[string, string]] and be annotated with {.async.}
  ##     The returned values are sent back to the ffi consumer thread.
  ##
  ## Example:
  ##   registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[Waku]):
  ##     proc(
  ##         config: NodeConfig, appCallbacks: AppCallbacks
  ##     ): Future[Result[string, string]] {.async.} =
  ##       ctx.myLib[] = (await createWaku(config, appCallbacks)).valueOr:
  ##         return err($error)
  ##       return ok("")
  ##
  ## The created FFI request is then dispatched from the ffi consumer thread
  ## (generally the main thread) following something like:
  ##
  ##   ffi.sendRequestToFFIThread(
  ##     ctx, CreateNodeRequest.ffiNewReq(callback, userData, config, appCallbacks)
  ##   ).isOkOr:
  ##     ...

  # Extract lambda params to generate fields
  let typeDef = buildRequestType(reqTypeName, body)
  let ffiNewReqProc = buildFFINewReqProc(reqTypeName, body)
  let processProc = buildProcessFFIRequestProc(reqTypeName, reqHandler, body)
  let addNewReqToReg = addNewRequestToRegistry(reqTypeName, reqHandler)
  let stmts = newStmtList(typeDef, ffiNewReqProc, processProc, addNewReqToReg)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

macro processReq*(
    reqType, ctx, callback, userData: untyped, args: varargs[untyped]
): untyped =
  ## Expands T.processReq(ctx, callback, userData, a, b, ...) into a
  ## sendRequestToFFIThread call that wraps the args in a freshly-built
  ## FFIThreadRequest, with inline error reporting via `callback`.
  ##
  ## e.g.:
  ##   waku_dial_peerReq.processReq(ctx, callback, userData, peerMultiAddr, protocol, timeoutMs)

  var callArgs = @[reqType, callback, userData]
  for a in args:
    callArgs.add a

  let newReqCall = newCall(ident("ffiNewReq"), callArgs)

  let sendCall = newCall(
    newDotExpr(ident("ffi_context"), ident("sendRequestToFFIThread")), ctx, newReqCall
  )

  let blockExpr = quote:
    block:
      let res = `sendCall`
      if res.isErr():
        let msg = "error in sendRequestToFFIThread: " & res.error
        `callback`(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), `userData`)
        return RET_ERR
      return RET_OK

  when defined(ffiDumpMacros):
    echo blockExpr.repr
  return blockExpr

macro ffiRaw*(prc: untyped): untyped =
  ## Defines an FFI-exported proc that registers a request handler to be executed
  ## asynchronously in the FFI thread.
  ##
  ## This is the "raw" / legacy form of the macro where the developer writes
  ## the ctx, callback, and userData parameters explicitly. Additional parameters
  ## travel as one CBOR blob.
  ##
  ## {.ffiRaw.} implicitly implies a Future[Result[string, string]] {.async.}
  ## return type.
  ##
  ## When using {.ffiRaw.}, the first three parameters must be:
  ##  - ctx: ptr FFIContext[T]  <-- T is the type that handles the FFI requests
  ##  - callback: FFICallBack
  ##  - userData: pointer
  ## Then, additional parameters may be defined as needed, after these first
  ## three, always considering that only no-GC'ed (or C-like) types are allowed.
  ##
  ## e.g.:
  ##   proc waku_version(
  ##       ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
  ##   ) {.ffiRaw.} =
  ##     return ok(WakuNodeVersionString)

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("`.ffiRaw.` procs require at least 1 parameter")

  let firstParam = formalParams[1]
  let paramIdent = firstParam[0]
  let paramType = firstParam[1]

  let libTypeName = paramType[0][1]
  let poolIdent = ident($libTypeName & "FFIPool")

  let reqName = ident($procName & "Req")
  let returnType = ident("cint")

  var newParams = newSeq[NimNode]()
  newParams.add(returnType)
  for i in 1 ..< formalParams.len:
    newParams.add(newIdentDefs(formalParams[i][0], formalParams[i][1]))

  let futReturnType = quote:
    Future[Result[string, string]]

  var userParams = newSeq[NimNode]()
  userParams.add(futReturnType)
  if formalParams.len > 3:
    for i in 4 ..< formalParams.len:
      userParams.add(newIdentDefs(formalParams[i][0], formalParams[i][1]))

  var argsList = newSeq[NimNode]()
  for i in 1 ..< formalParams.len:
    argsList.add(formalParams[i][0])

  let dotExpr = newTree(nnkDotExpr, reqName, ident"processReq")

  let callNode = newTree(nnkCall, dotExpr)
  for arg in argsList:
    callNode.add(arg)

  let ffiBody = newStmtList(
    quote do:
      initializeLibrary()
      if not `poolIdent`.isValidCtx(cast[pointer](ctx)):
        return RET_ERR
      ctx[].userData = userData
      if isNil(callback):
        return RET_MISSING_CALLBACK
  )

  ffiBody.add(callNode)

  let ffiProc = newProc(
    name = procName,
    params = newParams,
    body = ffiBody,
    pragmas = newTree(nnkPragma, ident "dynlib", ident "exportc", ident "cdecl"),
  )

  var anonymousProcNode = newProc(
    name = newEmptyNode(),
    params = userParams,
    body = newStmtList(bodyNode),
    pragmas = newTree(nnkPragma, ident"async"),
  )

  let registerReq = quote:
    registerReqFFI(`reqName`, `paramIdent`: `paramType`):
      `anonymousProcNode`

  let stmts = newStmtList(registerReq, ffiProc)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

# ---------------------------------------------------------------------------
# Native (zero-serialization) C-POD payload helpers, shared by the {.ffi.} and
# {.ffiCtor.} native code paths. The native path passes the typed args to the
# FFI thread inside a c_malloc'd struct (by pointer) instead of CBOR, so the
# struct keeps the user's original param types and owns copies of any cstrings.
# ---------------------------------------------------------------------------

proc isCstringType(t: NimNode): bool =
  t.kind == nnkIdent and $t == "cstring"

proc buildCArgsTypeDef(
    cargsTypeName: NimNode, paramNames: seq[string], paramTypes: seq[NimNode]
): NimNode =
  ## `type <cargsTypeName> = object` with one field per param (original types).
  ## Empty param lists get a `placeholder` field so the object is well-formed.
  var fields: seq[NimNode] = @[]
  for i in 0 ..< paramNames.len:
    fields.add(
      newTree(nnkIdentDefs, ident(paramNames[i]), paramTypes[i], newEmptyNode())
    )
  let recList =
    if fields.len > 0:
      newTree(nnkRecList, fields)
    else:
      newTree(
        nnkRecList,
        newTree(nnkIdentDefs, ident("placeholder"), ident("uint8"), newEmptyNode()),
      )
  return newNimNode(nnkTypeSection).add(
      newTree(
        nnkTypeDef,
        cargsTypeName,
        newEmptyNode(),
        newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList),
      )
    )

proc buildCArgsFreeProc(
    cargsTypeName, cargsFreeName: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
): NimNode =
  ## `proc <cargsFreeName>(p: pointer) {.cdecl, raises:[], gcsafe.}` that frees
  ## each owned cstring field (with c_free, matching `alloc`) and then the struct.
  let freeS = genSym(nskLet, "s")
  var freeBody = newStmtList()
  freeBody.add quote do:
    let `freeS` = cast[ptr `cargsTypeName`](p)
  for i in 0 ..< paramNames.len:
    if isCstringType(paramTypes[i]):
      let f = ident(paramNames[i])
      freeBody.add quote do:
        ffiCFree(cast[pointer](`freeS`[].`f`))
  freeBody.add quote do:
    ffiCFree(p)
  return newProc(
    name = cargsFreeName,
    params = @[newEmptyNode(), newIdentDefs(ident("p"), ident("pointer"))],
    body = freeBody,
    pragmas = newTree(
      nnkPragma,
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
      ident("gcsafe"),
    ),
  )

# ---------------------------------------------------------------------------
# ffi macro — primary FFI proc / FFI type registration
# ---------------------------------------------------------------------------

macro ffi*(prc: untyped): untyped =
  ## Simplified FFI macro — applies to procs or types.
  ##
  ## On a type: `type Foo {.ffi.} = object` registers Foo for binding generation
  ## and lets the generic cborEncode/cborDecode overloads handle serialization.
  ##
  ## On a proc: the annotated proc must have a first parameter of the library
  ## type, optionally additional Nim-typed parameters, and return
  ## Future[Result[RetType, string]]. It must NOT include ctx, callback, or
  ## userData in its signature — the macro generates a C-exported wrapper that
  ## takes one CBOR-encoded buffer as the call payload and fires the callback.
  ##
  ## Example (type):
  ##   type EchoRequest {.ffi.} = object
  ##     message: string
  ##     delayMs: int
  ##
  ## Example (proc):
  ##   proc mylib_send*(w: MyLib, cfg: SendConfig): Future[Result[string, string]] {.ffi.} =
  ##     return ok("done")

  if prc.kind == nnkTypeDef:
    var cleanTypeDef = prc.copyNimTree()
    if cleanTypeDef[0].kind == nnkPragmaExpr:
      cleanTypeDef[0] = cleanTypeDef[0][0]
    return registerFFITypeInfo(cleanTypeDef)

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("`.ffi.` procs require at least 1 parameter (the library type)")

  let firstParam = formalParams[1]
  let libParamName = firstParam[0]
  let libTypeName = firstParam[1]

  let retTypeNode = formalParams[0]
  if retTypeNode.kind == nnkEmpty:
    error(
      "`.ffi.` proc must have an explicit return type Future[Result[RetType, string]]"
    )
  if retTypeNode.kind != nnkBracketExpr or $retTypeNode[0] != "Future":
    error(
      "`.ffi.` return type must be Future[Result[RetType, string]], got: " &
        retTypeNode.repr
    )
  let resultInner = retTypeNode[1]
  if resultInner.kind != nnkBracketExpr or $resultInner[0] != "Result":
    error(
      "`.ffi.` return type must be Future[Result[RetType, string]], got: " &
        retTypeNode.repr
    )

  let resultRetType = resultInner[1]
  rejectRawPtrType(resultRetType, "`.ffi.` proc " & $procName & " return type")

  var extraParamNames: seq[string] = @[]
  var extraParamTypes: seq[NimNode] = @[]
  for i in 2 ..< formalParams.len:
    let p = formalParams[i]
    for j in 0 ..< p.len - 2:
      rejectRawPtrType(p[^2], "`.ffi.` proc " & $procName & " parameter " & $p[j])
      extraParamNames.add($p[j])
      extraParamTypes.add(p[^2])

  let procNameStr = block:
    let raw = $procName
    if raw.endsWith("*"):
      raw[0 ..^ 2]
    else:
      raw
  let cExportName = camelToSnakeCase(procNameStr)
  let camelName = snakeToPascalCase(procNameStr)

  let reqTypeName = ident(camelName & "Req")

  var userProcName = procName
  if procName.kind == nnkPostfix:
    userProcName = procName[1]
  ## Both the user-facing Nim proc and the C-exported wrapper share the user's
  ## original name; their signatures differ so Nim resolves the call by
  ## overload. The C wrapper additionally carries `{.exportc.}` so the foreign
  ## ABI symbol is unchanged.
  let cExportProcName = userProcName

  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  proc buildAsyncHelperProc(): NimNode =
    ## proc <userProcName>*(lib: LibType, extras...): Future[Result[T, string]] {.async.} = <body>
    var helperParams = newSeq[NimNode]()
    helperParams.add(retTypeNode)
    helperParams.add(newIdentDefs(libParamName, libTypeName))
    for i in 0 ..< extraParamNames.len:
      helperParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))
    newProc(
      name = postfix(userProcName, "*"),
      params = helperParams,
      body = newStmtList(bodyNode),
      pragmas = newTree(nnkPragma, ident("async")),
    )

  proc asyncPath(): NimNode =
    ## Emits the C-exported wrapper and registers the request handler.
    ## All `.ffi.` procs dispatch through the FFI thread channel and reply
    ## through the callback when the future resolves — the previous "sync
    ## fast-path" that ran inline on the foreign caller thread was removed
    ## (PR #23 review, items 1–5) because it bypassed `foreignThreadGc`,
    ## `ctx.lock`, and chronos's single-thread invariant.
    let helperProc = buildAsyncHelperProc()

    # registerReqFFI lambda: typed params, returns user's typed Result.
    let ctxHandlerName = ident("ffiCtxHandler")
    let ptrFFICtx =
      nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

    var lambdaParams = newSeq[NimNode]()
    lambdaParams.add(retTypeNode) # Future[Result[RetType, string]]
    for i in 0 ..< extraParamNames.len:
      lambdaParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))

    let ctxMyLib = newDotExpr(newTree(nnkDerefExpr, ctxHandlerName), ident("myLib"))
    let libValDeref = newTree(nnkDerefExpr, ctxMyLib)
    let helperCall = newTree(nnkCall, userProcName, libValDeref)
    for name in extraParamNames:
      helperCall.add(ident(name))

    let lambdaBody = newStmtList()
    let retValIdent = ident("retVal")
    lambdaBody.add quote do:
      let `retValIdent` = (await `helperCall`).valueOr:
        return err($error)
      return ok(`retValIdent`)

    let lambdaNode = newProc(
      name = newEmptyNode(),
      params = lambdaParams,
      body = lambdaBody,
      pragmas = newTree(nnkPragma, ident("async")),
    )

    let registerReq = quote:
      registerReqFFI(`reqTypeName`, `ctxHandlerName`: `ptrFFICtx`):
        `lambdaNode`

    # -------------------------------------------------------------------------
    # C-exported wrapper: takes (ctx, callback, userData, reqCbor, reqCborLen)
    # -------------------------------------------------------------------------
    let exportedParams = cExportedParams(ctxType)

    let ffiBody = newStmtList()

    ffiBody.add quote do:
      if callback.isNil:
        return RET_MISSING_CALLBACK

    let asyncPoolIdent = ident($libTypeName & "FFIPool")
    ffiBody.add quote do:
      if not `asyncPoolIdent`.isValidCtx(cast[pointer](ctx)):
        let errStr = "ctx is not a valid FFI context"
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR

    # Build the FFIThreadRequest payload directly from the incoming bytes.
    let reqPtrIdent = genSym(nskLet, "reqPtr")
    ffiBody.add quote do:
      let typeStr = $`reqTypeName`
      let `reqPtrIdent` = FFIThreadRequest.initFromPtr(
        callback, userData, typeStr.cstring, reqCbor, int(reqCborLen)
      )

    let sendResIdent = genSym(nskLet, "sendRes")
    ffiBody.add quote do:
      let `sendResIdent` =
        try:
          ffi_context.sendRequestToFFIThread(ctx, `reqPtrIdent`)
        except Exception as exc:
          Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
      if `sendResIdent`.isErr():
        let errStr = "error in sendRequestToFFIThread: " & `sendResIdent`.error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR
      return RET_OK

    # The CBOR entry point is the generic / cross-language dispatcher; it keeps
    # the per-proc Req type name as its handler key and is exported under the
    # `<name>_cbor` symbol. The native typed-arg entry point (below) is the
    # primary `<name>` symbol and is preferred for same-process callers.
    let cborExportName = ident(procNameStr & "CborExport")
    let ffiProc = newProc(
      name = cborExportName,
      params = exportedParams,
      body = ffiBody,
      pragmas = newTree(
        nnkPragma,
        ident("dynlib"),
        newTree(
          nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName & "_cbor")
        ),
        ident("cdecl"),
        newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
      ),
    )

    # -------------------------------------------------------------------------
    # Native (zero-serialization) path: the typed args travel to the FFI thread
    # inside a c_malloc'd C-POD struct passed by pointer — no CBOR — and the
    # response is delivered as raw bytes. Registered under a distinct
    # "<Camel>ReqNative" key so it dispatches to its own handler.
    # -------------------------------------------------------------------------
    let cargsTypeName = ident(camelName & "CArgs")
    let cargsFreeName = ident(camelName & "CArgsFree")
    let nativeReqIdLit = newStrLitNode(camelName & "ReqNative")
    let nativeExportName = ident(procNameStr & "NativeExport")

    let cargsTypeDef =
      buildCArgsTypeDef(cargsTypeName, extraParamNames, extraParamTypes)
    let cargsFreeProc =
      buildCArgsFreeProc(cargsTypeName, cargsFreeName, extraParamNames, extraParamTypes)

    # Native FFI-thread handler: read the C-POD, call the helper, raw-encode.
    let ndReq = genSym(nskLet, "ffiReq")
    let ndCtx = genSym(nskLet, "nativeCtx")
    let ndCargs = genSym(nskLet, "cargs")
    let ndRet = genSym(nskLet, "retVal")
    var ndBody = newStmtList()
    ndBody.add quote do:
      let `ndReq` = cast[ptr FFIThreadRequest](request)
      let `ndCtx` = cast[ptr FFIContext[`libTypeName`]](reqHandler)
      let `ndCargs` = cast[ptr `cargsTypeName`](`ndReq`[].data)
    let ndHelperCall = newTree(
      nnkCall,
      userProcName,
      newTree(nnkDerefExpr, newDotExpr(newTree(nnkDerefExpr, ndCtx), ident("myLib"))),
    )
    for nm in extraParamNames:
      let f = ident(nm)
      ndBody.add quote do:
        let `f` = `ndCargs`[].`f`
      ndHelperCall.add(ident(nm))
    ndBody.add quote do:
      let `ndRet` = (await `ndHelperCall`).valueOr:
        return err($error)
      when typeof(`ndRet`) is string:
        var rb = newSeq[byte](`ndRet`.len)
        if `ndRet`.len > 0:
          copyMem(addr rb[0], unsafeAddr `ndRet`[0], `ndRet`.len)
        return ok(rb)
      elif typeof(`ndRet`) is seq[byte]:
        return ok(`ndRet`)
      else:
        return ok(cborEncode(`ndRet`))
    let seqByteRet = nnkBracketExpr.newTree(
      ident("Future"),
      nnkBracketExpr.newTree(
        ident("Result"),
        nnkBracketExpr.newTree(ident("seq"), ident("byte")),
        ident("string"),
      ),
    )
    let nativeHandlerProc = newProc(
      name = newEmptyNode(),
      params = @[
        seqByteRet,
        newIdentDefs(ident("request"), ident("pointer")),
        newIdentDefs(ident("reqHandler"), ident("pointer")),
      ],
      body = ndBody,
      pragmas = nnkPragma.newTree(ident("async")),
    )
    let nativeRegister = newAssignment(
      newTree(nnkBracketExpr, ident("registeredRequests"), nativeReqIdLit),
      nativeHandlerProc,
    )

    # Native C export: build the C-POD (duplicating cstrings) and dispatch.
    let neCargs = genSym(nskLet, "cargs")
    let neReq = genSym(nskLet, "nreq")
    let neSend = genSym(nskLet, "sendRes")
    var neBody = newStmtList()
    neBody.add quote do:
      if callback.isNil:
        return RET_MISSING_CALLBACK
      if not `asyncPoolIdent`.isValidCtx(cast[pointer](ctx)):
        let errStr = "ctx is not a valid FFI context"
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR
      let `neCargs` = ffiCMalloc(`cargsTypeName`)
    for i in 0 ..< extraParamNames.len:
      let f = ident(extraParamNames[i])
      if isCstringType(extraParamTypes[i]):
        neBody.add quote do:
          `neCargs`[].`f` = `f`.alloc()
      else:
        neBody.add quote do:
          `neCargs`[].`f` = `f`
    neBody.add quote do:
      let `neReq` = FFIThreadRequest.initNative(
        callback,
        userData,
        `nativeReqIdLit`.cstring,
        cast[pointer](`neCargs`),
        `cargsFreeName`,
      )
      let `neSend` =
        try:
          ffi_context.sendRequestToFFIThread(ctx, `neReq`)
        except Exception as exc:
          Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
      if `neSend`.isErr():
        let errStr = "error in sendRequestToFFIThread: " & `neSend`.error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR
      return RET_OK
    var nativeExportParams = @[
      ident("cint"),
      newIdentDefs(ident("ctx"), ctxType),
      newIdentDefs(ident("callback"), ident("FFICallBack")),
      newIdentDefs(ident("userData"), ident("pointer")),
    ]
    for i in 0 ..< extraParamNames.len:
      nativeExportParams.add(
        newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i])
      )
    let nativeExportProc = newProc(
      name = nativeExportName,
      params = nativeExportParams,
      body = neBody,
      pragmas = newTree(
        nnkPragma,
        ident("dynlib"),
        newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
        ident("cdecl"),
        newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
      ),
    )

    block:
      var ffiExtraParams: seq[FFIParamMeta] = @[]
      for i in 0 ..< extraParamNames.len:
        let ptype = extraParamTypes[i]
        let isPointer = isPtr(ptype)
        let tn =
          if isPointer:
            nimTypeNameRepr(ptype[0])
          else:
            nimTypeNameRepr(ptype)
        ffiExtraParams.add(
          FFIParamMeta(name: extraParamNames[i], typeName: tn, isPtr: isPointer)
        )
      let retTypeInner = resultInner[1]
      let retIsPtr = isPtr(retTypeInner)
      let retTn =
        if retIsPtr:
          nimTypeNameRepr(retTypeInner[0])
        else:
          nimTypeNameRepr(retTypeInner)
      ffiProcRegistry.add(
        FFIProcMeta(
          procName: cExportName,
          libName: currentLibName,
          kind: FFIKind.FFI,
          libTypeName: $libTypeName,
          extraParams: ffiExtraParams,
          returnTypeName: retTn,
          returnIsPtr: retIsPtr,
        )
      )

    return newStmtList(
      helperProc, registerReq, cargsTypeDef, cargsFreeProc, nativeRegister,
      nativeExportProc, ffiProc,
    )

  let stmts = asyncPath()

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

# ---------------------------------------------------------------------------
# ffiCtor — constructor macro
# ---------------------------------------------------------------------------

proc buildCtorRequestType(
    reqTypeName: NimNode, paramNames: seq[string], paramTypes: seq[NimNode]
): NimNode =
  ## Builds the ctor's Req object using the user's actual Nim types.
  var fields: seq[NimNode] = @[]
  for i in 0 ..< paramNames.len:
    let fieldName = ident(paramNames[i])
    let storedType = storageType(paramTypes[i])
    fields.add newTree(nnkIdentDefs, fieldName, storedType, newEmptyNode())

  let recList =
    if fields.len > 0:
      newTree(nnkRecList, fields)
    else:
      newTree(
        nnkRecList,
        newTree(nnkIdentDefs, ident("_placeholder"), ident("uint8"), newEmptyNode()),
      )

  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)
  let typeName = postfix(reqTypeName, "*")
  let typeSection =
    newNimNode(nnkTypeSection).add(newTree(nnkTypeDef, typeName, newEmptyNode(), objTy))

  when defined(ffiDumpMacros):
    echo typeSection.repr
  return typeSection

proc buildCtorFFINewReqProc(reqTypeName: NimNode, paramNames: seq[string]): NimNode =
  ## Wraps a CBOR byte buffer into an FFIThreadRequest for the ctor request type.

  var formalParams = newSeq[NimNode]()

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  formalParams.add(newIdentDefs(ident("userData"), ident("pointer")))
  formalParams.add(newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte"))))
  formalParams.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))

  let retType = newTree(nnkPtrTy, ident("FFIThreadRequest"))
  formalParams = @[retType] & formalParams

  var newBody = newStmtList()
  newBody.add quote do:
    let typeStr = $T
    return FFIThreadRequest.initFromPtr(
      callback, userData, typeStr.cstring, reqCbor, int(reqCborLen)
    )

  let newReqProc = newProc(
    name = postfix(ident("ffiNewReq"), "*"),
    params = formalParams,
    body = newBody,
    pragmas = newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo newReqProc.repr
  return newReqProc

proc buildCtorBodyProc(
    helperName: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
    libTypeName: NimNode,
    userBody: NimNode,
): NimNode =
  let innerRetType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), libTypeName, ident("string")),
  )
  var innerParams = newSeq[NimNode]()
  innerParams.add(innerRetType)
  for i in 0 ..< paramNames.len:
    innerParams.add(newIdentDefs(ident(paramNames[i]), paramTypes[i]))

  let bodyProc = newProc(
    name = postfix(helperName, "*"),
    params = innerParams,
    body = newStmtList(userBody),
    pragmas = newTree(nnkPragma, ident("async")),
  )

  when defined(ffiDumpMacros):
    echo bodyProc.repr
  return bodyProc

proc buildCtorProcessFFIRequestProc(
    reqTypeName: NimNode,
    helperName: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
    libTypeName: NimNode,
): NimNode =
  ## Decodes the CBOR payload, unpacks fields, runs the user body, and stores
  ## the resulting library value in ctx.myLib.

  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), ident("string"), ident("string")),
  )

  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))

  var formalParams: seq[NimNode] = @[]
  formalParams.add(returnType)
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("request"), ident("pointer")))
  formalParams.add(newIdentDefs(ident("ctx"), ctxType))

  let newBody = newStmtList()
  let reqIdent = ident("req")
  let ctxIdent = ident("ctx")
  let decodedIdent = ident("decoded")

  newBody.add quote do:
    let `reqIdent` = cast[ptr FFIThreadRequest](request)
    let `decodedIdent` = cborDecodePtr(
      cast[ptr UncheckedArray[byte]](`reqIdent`[].data),
      `reqIdent`[].dataLen,
      `reqTypeName`,
    ).valueOr:
      return err("CBOR decode failed for " & $T & ": " & $error)

  for i in 0 ..< paramNames.len:
    newBody.add unpackReqField(ident(paramNames[i]), paramTypes[i], decodedIdent)

  let helperCallNode = newTree(nnkCall, helperName)
  for name in paramNames:
    helperCallNode.add(ident(name))

  let libValIdent = ident("libVal")
  newBody.add quote do:
    let `libValIdent` = (await `helperCallNode`).valueOr:
      return err($error)

  let myLibIdent = newDotExpr(newTree(nnkDerefExpr, ctxIdent), ident("myLib"))
  newBody.add quote do:
    `myLibIdent` = createShared(`libTypeName`)
    `myLibIdent`[] = `libValIdent`

  newBody.add quote do:
    return ok($cast[uint](`ctxIdent`))

  let processProc = newProc(
    name = postfix(ident("processFFIRequest"), "*"),
    params = formalParams,
    body = newBody,
    procType = nnkProcDef,
    pragmas = newTree(nnkPragma, ident("async")),
  )

  when defined(ffiDumpMacros):
    echo processProc.repr
  return processProc

proc addCtorRequestToRegistry(reqTypeName, libTypeName: NimNode): NimNode =
  ## Wraps the ctor processFFIRequest result in a seq[byte] dispatcher.
  ## The ctor uniquely returns the ctx address as a decimal string; we wrap
  ## it as raw UTF-8 bytes so the foreign side can read it back uniformly.

  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(
      ident("Result"),
      nnkBracketExpr.newTree(ident("seq"), ident("byte")),
      ident("string"),
    ),
  )

  let callExpr = newCall(
    newDotExpr(reqTypeName, ident("processFFIRequest")),
    ident("request"),
    newTree(nnkCast, ctxType, ident("reqHandler")),
  )

  let resIdent = genSym(nskLet, "ctorRes")
  var newBody = newStmtList()
  newBody.add quote do:
    let `resIdent` = await `callExpr`
    if `resIdent`.isErr:
      return err(`resIdent`.error)
    # The ctor returns the ctx address as a decimal string; encode it as CBOR text
    # for uniform decoding on the foreign side.
    return ok(cborEncode(`resIdent`.value))

  let asyncProc = newProc(
    name = newEmptyNode(),
    params = @[
      returnType,
      newIdentDefs(ident("request"), ident("pointer")),
      newIdentDefs(ident("reqHandler"), ident("pointer")),
    ],
    body = newBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )

  let key = newLit($reqTypeName)
  let regAssign =
    newAssignment(newTree(nnkBracketExpr, ident("registeredRequests"), key), asyncProc)

  when defined(ffiDumpMacros):
    echo regAssign.repr
  return regAssign

macro ffiCtor*(prc: untyped): untyped =
  ## Defines a C-exported constructor that creates an FFIContext and populates
  ## ctx.myLib asynchronously in the FFI thread.
  ##
  ## The annotated proc must:
  ##   - Have Nim-typed parameters (carried over the wire as a single CBOR blob)
  ##   - Return Future[Result[LibType, string]]
  ##   - NOT include ctx, callback, or userData in its signature
  ##
  ## Example:
  ##   proc mylib_create*(config: SimpleConfig): Future[Result[SimpleLib, string]] {.ffiCtor.} =
  ##     return ok(SimpleLib(value: config.initialValue))
  ##
  ## The generated C-exported proc has the signature:
  ##   proc mylib_create(reqCbor: ptr byte, reqCborLen: csize_t,
  ##                     callback: FFICallBack, userData: pointer): pointer
  ##                    {.exportc, cdecl, raises: [].}
  ##
  ## Returns the context pointer synchronously, NULL on failure. The callback
  ## also fires when async initialization completes, passing the ctx address as
  ## a decimal string on success. The caller should hold the returned pointer
  ## and pass it to subsequent .ffi. calls.

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  let retTypeNode = formalParams[0]
  if retTypeNode.kind == nnkEmpty:
    error(
      "ffiCtor: proc must have an explicit return type Future[Result[LibType, string]]"
    )
  if retTypeNode.kind != nnkBracketExpr or $retTypeNode[0] != "Future":
    error(
      "ffiCtor: return type must be Future[Result[LibType, string]], got: " &
        retTypeNode.repr
    )
  let resultInner = retTypeNode[1]
  if resultInner.kind != nnkBracketExpr or $resultInner[0] != "Result":
    error(
      "ffiCtor: return type must be Future[Result[LibType, string]], got: " &
        retTypeNode.repr
    )
  let libTypeName = resultInner[1]

  var paramNames: seq[string] = @[]
  var paramTypes: seq[NimNode] = @[]
  for i in 1 ..< formalParams.len:
    let p = formalParams[i]
    for j in 0 ..< p.len - 2:
      rejectRawPtrType(p[^2], "`.ffiCtor.` proc " & $procName & " parameter " & $p[j])
      paramNames.add($p[j])
      paramTypes.add(p[^2])

  let procNameStr = $procName
  let cleanName =
    if procNameStr.endsWith("*"):
      procNameStr[0 ..^ 2]
    else:
      procNameStr
  let cExportName = camelToSnakeCase(cleanName)
  let reqTypeNameStr = snakeToPascalCase(cleanName) & "CtorReq"
  let reqTypeName = ident(reqTypeNameStr)

  let typeDef = buildCtorRequestType(reqTypeName, paramNames, paramTypes)
  let ffiNewReqProc = buildCtorFFINewReqProc(reqTypeName, paramNames)
  # The user-facing Nim proc keeps the user's original name with their declared
  # signature; the C-exported wrapper moves to `<userProcName>ExportC` and
  # binds the snake_case C symbol via `{.exportc.}`.
  var userProcName = procName
  if procName.kind == nnkPostfix:
    userProcName = procName[1]
  # Both the Nim-facing async ctor and the C-exported wrapper share the user's
  # name as overloads; the C wrapper's `{.exportc.}` keeps the ABI symbol.
  let cExportProcName = userProcName
  let helperProc =
    buildCtorBodyProc(userProcName, paramNames, paramTypes, libTypeName, bodyNode)
  let processProc = buildCtorProcessFFIRequestProc(
    reqTypeName, userProcName, paramNames, paramTypes, libTypeName
  )
  let addToReg = addCtorRequestToRegistry(reqTypeName, libTypeName)

  # C-exported proc: (reqCbor, reqCborLen, callback, userData) -> pointer
  var exportedParams = newSeq[NimNode]()
  exportedParams.add(ident("pointer"))
  exportedParams.add(newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte"))))
  exportedParams.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))
  exportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  exportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  let ffiBody = newStmtList()

  ffiBody.add quote do:
    when declared(initializeLibrary):
      initializeLibrary()

  let ctxSym = genSym(nskLet, "ctx")
  let poolIdent = ident($libTypeName & "FFIPool")

  ffiBody.add quote do:
    let `ctxSym` = `poolIdent`.createFFIContext().valueOr:
      if not callback.isNil:
        let errStr = "ffiCtor: failed to create FFIContext: " & $error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return nil

  # Early validation: decode the CBOR payload to verify it parses cleanly.
  ffiBody.add quote do:
    block:
      let validateRes = cborDecodePtr(
        cast[ptr UncheckedArray[byte]](reqCbor), int(reqCborLen), `reqTypeName`
      )
      if validateRes.isErr():
        if not callback.isNil:
          let errStr = "ffiCtor: failed to decode request: " & $validateRes.error
          callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return nil

  let newReqCall = newCall(
    ident("ffiNewReq"),
    reqTypeName,
    ident("callback"),
    ident("userData"),
    ident("reqCbor"),
    ident("reqCborLen"),
  )

  let sendCall =
    newCall(newDotExpr(ctxSym, ident("sendRequestToFFIThread")), newReqCall)

  let sendResIdent = genSym(nskLet, "sendRes")
  ffiBody.add quote do:
    let `sendResIdent` =
      try:
        `sendCall`
      except Exception as exc:
        Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
    if `sendResIdent`.isErr():
      if not callback.isNil:
        let errStr = "ffiCtor: failed to send request: " & $`sendResIdent`.error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return nil

  ffiBody.add quote do:
    return cast[pointer](`ctxSym`)

  # CBOR constructor entry point, exported under `<name>_cbor`. The native
  # typed-arg constructor below is the primary `<name>` symbol.
  let cborCtorExportName = ident(cleanName & "CborCtorExport")
  let ffiProc = newProc(
    name = cborCtorExportName,
    params = exportedParams,
    body = ffiBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName & "_cbor")),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  block:
    var ctorExtraParams: seq[FFIParamMeta] = @[]
    for i in 0 ..< paramNames.len:
      let ptype = paramTypes[i]
      let isPointer = isPtr(ptype)
      let tn =
        if isPointer:
          nimTypeNameRepr(ptype[0])
        else:
          nimTypeNameRepr(ptype)
      ctorExtraParams.add(
        FFIParamMeta(name: paramNames[i], typeName: tn, isPtr: isPointer)
      )
    ffiProcRegistry.add(
      FFIProcMeta(
        procName: cExportName,
        libName: currentLibName,
        kind: FFIKind.CTOR,
        libTypeName: $libTypeName,
        extraParams: ctorExtraParams,
        returnTypeName: $libTypeName,
        returnIsPtr: false,
      )
    )

  # -------------------------------------------------------------------------
  # Native (zero-serialization) constructor: typed args -> C-POD by pointer,
  # exported as the primary `<name>` symbol. Returns the ctx pointer; the
  # callback fires with the ctx address as a raw decimal string.
  # -------------------------------------------------------------------------
  let ctorCamel = snakeToPascalCase(cleanName)
  let cargsTypeName = ident(ctorCamel & "CtorCArgs")
  let cargsFreeName = ident(ctorCamel & "CtorCArgsFree")
  let nativeCtorReqIdLit = newStrLitNode(ctorCamel & "CtorReqNative")
  let nativeCtorExportName = ident(cleanName & "NativeCtorExport")

  let ctorCargsTypeDef = buildCArgsTypeDef(cargsTypeName, paramNames, paramTypes)
  let ctorCargsFreeProc =
    buildCArgsFreeProc(cargsTypeName, cargsFreeName, paramNames, paramTypes)

  # Native handler: read the C-POD, run the ctor body, store myLib, raw address.
  let ncReq = genSym(nskLet, "ffiReq")
  let ncCtx = genSym(nskLet, "nativeCtx")
  let ncCargs = genSym(nskLet, "cargs")
  let ncLibVal = genSym(nskLet, "libVal")
  let ncAddr = genSym(nskLet, "addrStr")
  var ncBody = newStmtList()
  ncBody.add quote do:
    let `ncReq` = cast[ptr FFIThreadRequest](request)
    let `ncCtx` = cast[ptr FFIContext[`libTypeName`]](reqHandler)
    let `ncCargs` = cast[ptr `cargsTypeName`](`ncReq`[].data)
  let ncHelperCall = newTree(nnkCall, userProcName)
  for nm in paramNames:
    let f = ident(nm)
    ncBody.add quote do:
      let `f` = `ncCargs`[].`f`
    ncHelperCall.add(ident(nm))
  let ncMyLib = newDotExpr(newTree(nnkDerefExpr, ncCtx), ident("myLib"))
  ncBody.add quote do:
    let `ncLibVal` = (await `ncHelperCall`).valueOr:
      return err($error)
    `ncMyLib` = createShared(`libTypeName`)
    `ncMyLib`[] = `ncLibVal`
    let `ncAddr` = $cast[uint](`ncCtx`)
    var rb = newSeq[byte](`ncAddr`.len)
    if `ncAddr`.len > 0:
      copyMem(addr rb[0], unsafeAddr `ncAddr`[0], `ncAddr`.len)
    return ok(rb)
  let ctorSeqByteRet = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(
      ident("Result"),
      nnkBracketExpr.newTree(ident("seq"), ident("byte")),
      ident("string"),
    ),
  )
  let nativeCtorHandler = newProc(
    name = newEmptyNode(),
    params = @[
      ctorSeqByteRet,
      newIdentDefs(ident("request"), ident("pointer")),
      newIdentDefs(ident("reqHandler"), ident("pointer")),
    ],
    body = ncBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )
  let nativeCtorRegister = newAssignment(
    newTree(nnkBracketExpr, ident("registeredRequests"), nativeCtorReqIdLit),
    nativeCtorHandler,
  )

  # Native C export: create the ctx, build the C-POD (dup cstrings), dispatch.
  let necCtx = genSym(nskLet, "ctx")
  let necCargs = genSym(nskLet, "cargs")
  let necReq = genSym(nskLet, "nreq")
  let necSend = genSym(nskLet, "sendRes")
  var necBody = newStmtList()
  necBody.add quote do:
    when declared(initializeLibrary):
      initializeLibrary()
    let `necCtx` = `poolIdent`.createFFIContext().valueOr:
      if not callback.isNil:
        let errStr = "ffiCtor: failed to create FFIContext: " & $error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return nil
    let `necCargs` = ffiCMalloc(`cargsTypeName`)
  for i in 0 ..< paramNames.len:
    let f = ident(paramNames[i])
    if isCstringType(paramTypes[i]):
      necBody.add quote do:
        `necCargs`[].`f` = `f`.alloc()
    else:
      necBody.add quote do:
        `necCargs`[].`f` = `f`
  necBody.add quote do:
    let `necReq` = FFIThreadRequest.initNative(
      callback,
      userData,
      `nativeCtorReqIdLit`.cstring,
      cast[pointer](`necCargs`),
      `cargsFreeName`,
    )
    let `necSend` =
      try:
        `necCtx`.sendRequestToFFIThread(`necReq`)
      except Exception as exc:
        Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
    if `necSend`.isErr():
      if not callback.isNil:
        let errStr = "ffiCtor: failed to send request: " & $`necSend`.error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return nil
    return cast[pointer](`necCtx`)
  var nativeCtorParams = @[ident("pointer")]
  for i in 0 ..< paramNames.len:
    nativeCtorParams.add(newIdentDefs(ident(paramNames[i]), paramTypes[i]))
  nativeCtorParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  nativeCtorParams.add(newIdentDefs(ident("userData"), ident("pointer")))
  let nativeCtorExportProc = newProc(
    name = nativeCtorExportName,
    params = nativeCtorParams,
    body = necBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  let poolDecl = quote:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts = newStmtList(
    typeDef, ffiNewReqProc, helperProc, processProc, addToReg, poolDecl, ffiProc,
    ctorCargsTypeDef, ctorCargsFreeProc, nativeCtorRegister, nativeCtorExportProc,
  )

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

# ---------------------------------------------------------------------------
# ffiDtor — destructor macro
# ---------------------------------------------------------------------------

macro ffiDtor*(prc: untyped): untyped =
  ## Defines a C-exported destructor that tears down the FFIContext after the
  ## body runs.
  ##
  ## The annotated proc must have exactly one parameter of the library type.
  ## The body contains any library-level cleanup to run before context teardown.
  ##
  ## Example:
  ##   proc waku_destroy*(w: Waku) {.ffiDtor.} =
  ##     w.cleanup()
  ##
  ## The generated C-exported proc has the signature:
  ##   int waku_destroy(void* ctx)
  ##
  ## It extracts the library value from ctx, runs the body, then calls
  ## destroyFFIContext to tear down the FFI thread and free the context.
  ## Returns RET_OK on success, RET_ERR on failure (null/invalid ctx, or
  ## destroyFFIContext failure).

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("ffiDtor: proc must have exactly one parameter (w: LibType)")

  let libParamName = formalParams[1][0]
  let libTypeName = formalParams[1][1]

  let procNameStr = block:
    let raw = $procName
    if raw.endsWith("*"):
      raw[0 ..^ 2]
    else:
      raw
  let cExportName = camelToSnakeCase(procNameStr)
  # The dtor only needs a C-exported wrapper; rename to a synthetic Nim ident
  # so it doesn't shadow the user's chosen name (consistent with .ffi. / .ffiCtor.).
  # The dtor only generates a C-exported wrapper; it uses the user's name
  # directly (no overload needed — there's no Nim-facing helper here).
  var cExportProcName = procName
  if procName.kind == nnkPostfix:
    cExportProcName = procName[1]

  let destroyResIdent = genSym(nskLet, "destroyRes")

  let ffiBody = newStmtList()

  ffiBody.add quote do:
    when declared(initializeLibrary):
      initializeLibrary()

  ffiBody.add quote do:
    if ctx.isNil or cast[ptr FFIContext[`libTypeName`]](ctx)[].myLib.isNil:
      return RET_ERR

  ffiBody.add quote do:
    let `libParamName` = cast[ptr FFIContext[`libTypeName`]](ctx)[].myLib[]

  let isNoop =
    bodyNode.kind == nnkEmpty or (
      bodyNode.kind == nnkStmtList and bodyNode.len == 1 and
      bodyNode[0].kind == nnkDiscardStmt
    )
  if not isNoop:
    ffiBody.add(bodyNode)

  let poolIdent = ident($libTypeName & "FFIPool")
  ffiBody.add quote do:
    let `destroyResIdent` =
      `poolIdent`.destroyFFIContext(cast[ptr FFIContext[`libTypeName`]](ctx))
    if `destroyResIdent`.isErr():
      return RET_ERR

  ffiBody.add quote do:
    return RET_OK

  let ffiProc = newProc(
    name = postfix(cExportProcName, "*"),
    params = @[ident("cint"), newIdentDefs(ident("ctx"), ident("pointer"))],
    body = ffiBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  ffiProcRegistry.add(
    FFIProcMeta(
      procName: cExportName,
      libName: currentLibName,
      kind: FFIKind.DTOR,
      libTypeName: $libTypeName,
      extraParams: @[],
      returnTypeName: "",
      returnIsPtr: false,
    )
  )

  let poolDecl = quote:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts = newStmtList(poolDecl, ffiProc)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

# ---------------------------------------------------------------------------
# ffiEvent — library-initiated typed event
# ---------------------------------------------------------------------------

macro ffiEvent*(wireName: static[string], prc: untyped): untyped =
  ## Declares a library-initiated event. The annotated proc has an empty
  ## body — the macro fills it with a `dispatchFFIEventCbor` call so the
  ## Nim author dispatches the event by calling the proc with a typed
  ## payload, and the per-target codegens emit a typed handler dispatcher
  ## on the foreign side.
  ##
  ## The pragma takes the wire-format event name verbatim (no case
  ## conversion). That string appears in the CBOR `eventType` field and is
  ## the single source of truth across Nim / C++ / Rust bindings.
  ##
  ## Example:
  ##   type PeerInfo {.ffi.} = object
  ##     id: string
  ##     address: string
  ##
  ##   proc onPeerConnected*(peer: PeerInfo) {.ffiEvent: "on_peer_connected".}
  ##
  ##   # ... then from inside any {.ffi.} handler:
  ##   onPeerConnected(PeerInfo(id: "p-1", address: "127.0.0.1"))
  ##
  ## Restriction (first pass): exactly one parameter. Multi-param events
  ## need a synthesised envelope struct; planned for a follow-up.

  if prc.kind notin {nnkProcDef, nnkFuncDef}:
    error("ffiEvent must be applied to a proc declaration")

  let procName = prc[0]
  let formalParams = prc[3]

  if formalParams.len != 2:
    error(
      "ffiEvent (first pass) supports exactly one parameter; got " &
        $(formalParams.len - 1)
    )

  let paramDef = formalParams[1]
  let payloadParamName = paramDef[0]
  let payloadTypeNode = paramDef[1]

  let payloadTypeNameStr =
    case payloadTypeNode.kind
    of nnkIdent:
      $payloadTypeNode
    else:
      payloadTypeNode.repr

  var userProcName = procName
  if procName.kind == nnkPostfix:
    userProcName = procName[1]

  # The generated body: dispatchFFIEventCbor("wire_name", payload).
  let wireNameLit = newStrLitNode(wireName)
  let dispatchBody =
    newStmtList(newCall(ident("dispatchFFIEventCbor"), wireNameLit, payloadParamName))

  var newParams = newSeq[NimNode]()
  newParams.add(formalParams[0]) # return type (typically empty/void)
  newParams.add(paramDef)

  let pragmas =
    if prc.len >= 5 and prc[4].kind != nnkEmpty:
      prc[4]
    else:
      newEmptyNode()

  let generated = newProc(
    name = procName,
    params = newParams,
    body = dispatchBody,
    procType = prc.kind,
    pragmas = pragmas,
  )

  ffiEventRegistry.add(
    FFIEventMeta(
      wireName: wireName,
      nimProcName: $userProcName,
      libName: currentLibName,
      payloadTypeName: payloadTypeNameStr,
    )
  )

  when defined(ffiDumpMacros):
    echo generated.repr
  return generated

# ---------------------------------------------------------------------------
# genBindings — codegen entry point
# ---------------------------------------------------------------------------

macro genBindings*(
    outputDir: static[string] = ffiOutputDir, nimSrcRelPath: static[string] = ffiSrcPath
): untyped =
  ## Emits C++ or Rust binding files from the compile-time FFI registries.
  ## The foreign-side wrapper encodes one CBOR buffer per request.
  ##
  ## PLACEMENT REQUIREMENT: genBindings() must be called AFTER every {.ffi.},
  ## {.ffiCtor.} and {.ffiDtor.} annotation in the compilation unit. Each
  ## pragma populates ffiProcRegistry / ffiTypeRegistry as the compiler
  ## expands the AST; calling genBindings() earlier produces incomplete
  ## bindings.
  ##
  ## In a single-file library, place it at the bottom of the file.
  ## In a multi-file library, import all sub-modules first and call
  ## genBindings() once at the bottom of the top-level compilation-root file.
  ##
  ## Supported languages (-d:targetLang): "rust" (default), "cpp".
  ## Output path and nim source path default to -d:ffiOutputDir and
  ## -d:ffiSrcPath, or can be passed as explicit arguments.
  ## This macro is a no-op unless -d:ffiGenBindings is set.
  ##
  ## Example (all via compile flags):
  ##   genBindings()
  ##   # nim c -d:ffiGenBindings -d:targetLang=rust \
  ##   #        -d:ffiOutputDir=examples/timer/rust_bindings \
  ##   #        -d:ffiSrcPath=../timer.nim mylib.nim

  when defined(ffiGenBindings):
    if outputDir.len == 0:
      error(
        "genBindings: output directory is empty." &
          " Pass it as an argument or set -d:ffiOutputDir=path/to/output"
      )
    let lang = string_helpers.toLower(targetLang)
    let libName = deriveLibName(ffiProcRegistry)
    case lang
    of "rust":
      generateRustCrate(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath,
        ffiEventRegistry,
      )
    of "cpp", "c++":
      generateCppBindings(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath,
        ffiEventRegistry,
      )
    of "cddl":
      generateCddlBindings(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath
      )
    of "c":
      generateCBindings(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath,
        ffiEventRegistry,
      )
    of "go":
      generateGoBindings(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath,
        ffiEventRegistry,
      )
    else:
      error(
        "genBindings: unknown targetLang '" & lang &
          "'. Use 'c', 'go', 'rust', 'cpp', or 'cddl'."
      )

  return newEmptyNode()
