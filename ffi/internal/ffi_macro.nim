import std/[macros, tables, strutils]
import chronos
import ../ffi_types
import ../codegen/meta
when defined(ffiGenBindings):
  import ../codegen/rust
  import ../codegen/cpp

# ---------------------------------------------------------------------------
# String helpers used by multiple macros
# ---------------------------------------------------------------------------

proc nimNameToCExport(s: string): string =
  ## Converts a camelCase Nim proc name to a snake_case C export name.
  ## Leaves already-snake_case names unchanged.
  ## e.g. "timerCreate" → "timer_create", "timer_echo" → "timer_echo"
  var snake = ""
  for i, c in s:
    if c.isUpperAscii() and i > 0:
      snake.add('_')
    snake.add(c.toLowerAscii())
  return snake

proc registerFfiTypeInfo(typeDef: NimNode): NimNode {.compileTime.} =
  ## Registers the type in ffiTypeRegistry for binding generation and returns
  ## the clean typeDef. Serialization is handled by the generic overloads in
  ## cbor_serial.nim.
  let typeName =
    if typeDef[0].kind == nnkPostfix: typeDef[0][1] else: typeDef[0]
  let typeNameStr = $typeName

  var fieldMetas: seq[FFIFieldMeta] = @[]
  let objTy = typeDef[2]
  if objTy.kind == nnkObjectTy and objTy.len >= 3:
    let recList = objTy[2]
    if recList.kind == nnkRecList:
      for identDef in recList:
        if identDef.kind == nnkIdentDefs:
          let fieldType = identDef[^2]
          let fieldTypeName =
            if fieldType.kind == nnkIdent: $fieldType
            elif fieldType.kind == nnkPtrTy: "ptr " & $fieldType[0]
            else: fieldType.repr
          for i in 0 ..< identDef.len - 2:
            fieldMetas.add(FFIFieldMeta(name: $identDef[i], typeName: fieldTypeName))

  ffiTypeRegistry.add(FFITypeMeta(name: typeNameStr, fields: fieldMetas))
  return typeDef

proc bodyHasAwait(n: NimNode): bool =
  ## Returns true if the AST node `n` contains any `await` or `waitFor` call.
  if n.kind in {nnkCall, nnkCommand}:
    let callee = n[0]
    if callee.kind == nnkIdent and callee.strVal in ["await", "waitFor"]:
      return true
  for child in n:
    if bodyHasAwait(child):
      return true
  false

proc nimTypeNameRepr(typ: NimNode): string =
  ## Stringifies a parameter or field type for the binding-generator registry.
  ## `$ident` works for simple types; bracket/dot/expression types need `repr`.
  case typ.kind
  of nnkIdent: $typ
  of nnkPtrTy: "ptr " & nimTypeNameRepr(typ[0])
  else: typ.repr

proc fieldStorageType(typ: NimNode): NimNode =
  ## Returns the in-Req-struct storage type for a user-declared param type.
  ## `cstring` is stored as `string` for trivial CBOR transport; everything
  ## else is stored as the user typed it.
  case typ.kind
  of nnkIdent:
    if $typ == "cstring": ident("string")
    else: typ
  else: typ

proc buildRequestType(reqTypeName: NimNode, body: NimNode): NimNode =
  ## Builds the per-proc Req object type. Field names match the lambda params;
  ## field types match the user-typed param types (with cstring rewritten to
  ## string for transport).

  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda proc, found: " & $procNode.kind

  let params = procNode[3]
  var fields: seq[NimNode] = @[]
  for p in params[1 .. ^1]:
    let name = p[0]
    let typ = fieldStorageType(p[1])
    fields.add newTree(nnkIdentDefs, name, typ, newEmptyNode())

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

  let typeSection =
    newNimNode(nnkTypeSection).add(newTree(nnkTypeDef, typeName, newEmptyNode(), objTy))

  when defined(ffiDumpMacros):
    echo typeSection.repr
  return typeSection

proc buildFfiNewReqProc(reqTypeName, body: NimNode): NimNode =
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
  let typedescParam = newIdentDefs(
    ident("T"),
    nnkBracketExpr.newTree(ident("typedesc"), reqTypeName),
  )
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
    let storeAsString =
      userType.kind == nnkIdent and $userType == "cstring"
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
      let bytes = cborEncode(`reqObjIdent`)
      return FFIThreadRequest.init(callback, userData, typeStr.cstring, bytes)
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
    let `reqIdent`: ptr FFIThreadRequest =
      cast[ptr FFIThreadRequest](request)
    let `decodedIdent` =
      cborDecodePtr(
        cast[ptr UncheckedArray[byte]](`reqIdent`[].data),
        `reqIdent`[].dataLen,
        `reqTypeName`,
      ).valueOr:
        return err("CBOR decode failed for " & $T & ": " & $error)

  # Unpack each field as a local typed as the user's original param type.
  for p in procParams[1 ..^ 1]:
    let fieldName = p[0]
    let userType = p[1]
    let storedAsString =
      userType.kind == nnkIdent and $userType == "cstring"
    if storedAsString:
      newBody.add quote do:
        let `fieldName`: cstring = (`decodedIdent`.`fieldName`).cstring
    else:
      newBody.add quote do:
        let `fieldName` = `decodedIdent`.`fieldName`

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

  let castedHandler = newTree(
    nnkCast,
    rhsType,
    ident("reqHandler"),
  )

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
  ## Registers a request type and its FFI-thread handler.
  ##
  ## Example:
  ##   registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[Waku]):
  ##     proc(config: NodeConfig): Future[Result[string, string]] {.async.} =
  ##       ...

  let typeDef = buildRequestType(reqTypeName, body)
  let ffiNewReqProc = buildFfiNewReqProc(reqTypeName, body)
  let processProc = buildProcessFFIRequestProc(reqTypeName, reqHandler, body)
  let addNewReqToReg = addNewRequestToRegistry(reqTypeName, reqHandler)
  let stmts = newStmtList(typeDef, ffiNewReqProc, processProc, addNewReqToReg)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

macro processReq*(
    reqType, ctx, callback, userData: untyped, args: varargs[untyped]
): untyped =
  ## Expands T.processReq(ctx, callback, userData, a, b, ...)

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
  ## asynchronously in the FFI thread. {.ffiRaw.} keeps the ctx/callback/userData
  ## params explicit; additional parameters are encoded as one CBOR blob.

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
# ffi macro — primary FFI proc / FFI type registration
# ---------------------------------------------------------------------------

macro ffi*(prc: untyped): untyped =
  ## Simplified FFI macro — applies to procs or types.
  ##
  ## On a type: `type Foo {.ffi.} = object` registers Foo for binding generation.
  ## On a proc: the annotated proc must have a first parameter of the library
  ## type, optionally additional Nim-typed parameters, and return
  ## Future[Result[RetType, string]]. The macro generates a C-exported wrapper
  ## that takes one CBOR-encoded buffer as the call payload.

  if prc.kind == nnkTypeDef:
    var cleanTypeDef = prc.copyNimTree()
    if cleanTypeDef[0].kind == nnkPragmaExpr:
      cleanTypeDef[0] = cleanTypeDef[0][0]
    return registerFfiTypeInfo(cleanTypeDef)

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

  var extraParamNames: seq[string] = @[]
  var extraParamTypes: seq[NimNode] = @[]
  for i in 2 ..< formalParams.len:
    let p = formalParams[i]
    for j in 0 ..< p.len - 2:
      extraParamNames.add($p[j])
      extraParamTypes.add(p[^2])

  let procNameStr = block:
    let raw = $procName
    if raw.endsWith("*"):
      raw[0 ..^ 2]
    else:
      raw
  let cExportName = nimNameToCExport(procNameStr)
  let camelName = snakeToPascalCase(procNameStr)

  let reqTypeName = ident(camelName & "Req")

  let isAsync = bodyHasAwait(bodyNode)

  let userProcName =
    if procName.kind == nnkPostfix:
      procName[1]
    else:
      procName
  ## Both the user-facing Nim proc and the C-exported wrapper share the user's
  ## original name; their signatures differ so Nim resolves the call by
  ## overload. The C wrapper additionally carries `{.exportc.}` so the foreign
  ## ABI symbol is unchanged.
  let cExportProcName = userProcName
  ## Sync-only helper that owns the user body when there's no `await`. The
  ## C-export inlines this for the fast path; the Nim-facing user proc wraps
  ## its result in a completed Future so the declared `Future[...]` shape holds.
  let syncBodyProcName = ident($userProcName & "Sync")

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

  proc buildSyncBodyHelperProc(): NimNode =
    ## proc <syncBodyProcName>*(lib: LibType, extras...): Result[T, string] = <body>
    var helperParams = newSeq[NimNode]()
    helperParams.add(resultInner)
    helperParams.add(newIdentDefs(libParamName, libTypeName))
    for i in 0 ..< extraParamNames.len:
      helperParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))
    newProc(
      name = postfix(syncBodyProcName, "*"),
      params = helperParams,
      body = newStmtList(bodyNode.copyNimTree()),
      pragmas = newEmptyNode(),
    )

  proc buildSyncAsyncWrapperProc(): NimNode =
    ## proc <userProcName>*(lib: LibType, extras...): Future[Result[T, string]] {.async.} =
    ##   return <syncBodyProcName>(lib, extras...)
    var wrapperParams = newSeq[NimNode]()
    wrapperParams.add(retTypeNode)
    wrapperParams.add(newIdentDefs(libParamName, libTypeName))
    for i in 0 ..< extraParamNames.len:
      wrapperParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))
    let callNode = newCall(syncBodyProcName, libParamName)
    for n in extraParamNames:
      callNode.add(ident(n))
    let body = newStmtList(newTree(nnkReturnStmt, callNode))
    newProc(
      name = postfix(userProcName, "*"),
      params = wrapperParams,
      body = body,
      pragmas = newTree(nnkPragma, ident("async")),
    )

  var stmts: NimNode
  if isAsync:
    # -------------------------------------------------------------------------
    # ASYNC PATH
    # -------------------------------------------------------------------------
    let helperProc = buildAsyncHelperProc()

    # registerReqFFI lambda: typed params, returns user's typed Result.
    let ctxHandlerName = ident("ffiCtxHandler")
    let ptrFfiCtx =
      nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

    var lambdaParams = newSeq[NimNode]()
    lambdaParams.add(retTypeNode) # Future[Result[RetType, string]]
    for i in 0 ..< extraParamNames.len:
      lambdaParams.add(
        newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i])
      )

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
      registerReqFFI(`reqTypeName`, `ctxHandlerName`: `ptrFfiCtx`):
        `lambdaNode`

    # -------------------------------------------------------------------------
    # C-exported wrapper: takes (ctx, callback, userData, reqCbor, reqCborLen)
    # -------------------------------------------------------------------------
    var exportedParams = newSeq[NimNode]()
    exportedParams.add(ident("cint"))
    exportedParams.add(newIdentDefs(ident("ctx"), ctxType))
    exportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
    exportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))
    exportedParams.add(
      newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte")))
    )
    exportedParams.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))

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

    let ffiProc = newProc(
      name = postfix(cExportProcName, "*"),
      params = exportedParams,
      body = ffiBody,
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
        let isPtr = ptype.kind == nnkPtrTy
        let tn =
          if isPtr: nimTypeNameRepr(ptype[0])
          else: nimTypeNameRepr(ptype)
        ffiExtraParams.add(
          FFIParamMeta(name: extraParamNames[i], typeName: tn, isPtr: isPtr)
        )
      let retTypeInner = resultInner[1]
      let retIsPtr = retTypeInner.kind == nnkPtrTy
      let retTn =
        if retIsPtr: nimTypeNameRepr(retTypeInner[0])
        else: nimTypeNameRepr(retTypeInner)
      ffiProcRegistry.add(
        FFIProcMeta(
          procName: cExportName,
          libName: currentLibName,
          kind: FFIKind.FFI,
          libTypeName: $libTypeName,
          extraParams: ffiExtraParams,
          returnTypeName: retTn,
          returnIsPtr: retIsPtr,
          isAsync: true,
        )
      )

    stmts = newStmtList(helperProc, registerReq, ffiProc)
  else:
    # -------------------------------------------------------------------------
    # SYNC PATH — bypass thread channel; fire callback inline
    # -------------------------------------------------------------------------
    let syncBodyProc = buildSyncBodyHelperProc()
    let userAsyncWrapper = buildSyncAsyncWrapperProc()

    # Declare the Req type so we can CBOR-decode the incoming payload uniformly.
    var syncReqFields: seq[NimNode] = @[]
    for i in 0 ..< extraParamNames.len:
      let fieldName = ident(extraParamNames[i])
      let storedType = fieldStorageType(extraParamTypes[i])
      syncReqFields.add newTree(nnkIdentDefs, fieldName, storedType, newEmptyNode())
    let syncReqRecList =
      if syncReqFields.len > 0:
        newTree(nnkRecList, syncReqFields)
      else:
        newTree(
          nnkRecList,
          newTree(nnkIdentDefs, ident("_placeholder"), ident("uint8"), newEmptyNode()),
        )
    let syncReqObjTy =
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), syncReqRecList)
    let syncReqTypeDef = newNimNode(nnkTypeSection).add(
      newTree(nnkTypeDef, postfix(reqTypeName, "*"), newEmptyNode(), syncReqObjTy)
    )

    var syncExportedParams = newSeq[NimNode]()
    syncExportedParams.add(ident("cint"))
    syncExportedParams.add(newIdentDefs(ident("ctx"), ctxType))
    syncExportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
    syncExportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))
    syncExportedParams.add(
      newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte")))
    )
    syncExportedParams.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))

    let syncFfiBody = newStmtList()

    syncFfiBody.add quote do:
      if callback.isNil:
        return RET_MISSING_CALLBACK

    let syncPoolIdent = ident($libTypeName & "FFIPool")
    syncFfiBody.add quote do:
      if not `syncPoolIdent`.isValidCtx(cast[pointer](ctx)):
        let errStr = "ctx is not a valid FFI context"
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR

    # CBOR-decode the incoming payload into the Req struct.
    let decodedIdent = genSym(nskLet, "decoded")
    syncFfiBody.add quote do:
      let `decodedIdent` =
        block:
          let decodeRes = cborDecodePtr(
            cast[ptr UncheckedArray[byte]](reqCbor), int(reqCborLen), `reqTypeName`
          )
          if decodeRes.isErr:
            let errStr = "CBOR decode failed: " & decodeRes.error
            callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
            return RET_ERR
          decodeRes.value

    # Unpack fields with the user's original parameter types.
    for i in 0 ..< extraParamNames.len:
      let fieldIdent = ident(extraParamNames[i])
      let userType = extraParamTypes[i]
      let storedAsString =
        userType.kind == nnkIdent and $userType == "cstring"
      if storedAsString:
        syncFfiBody.add quote do:
          let `fieldIdent`: cstring = (`decodedIdent`.`fieldIdent`).cstring
      else:
        syncFfiBody.add quote do:
          let `fieldIdent` = `decodedIdent`.`fieldIdent`

    let syncCtxMyLib = newDotExpr(newTree(nnkDerefExpr, ident("ctx")), ident("myLib"))
    let syncLibValDeref = newTree(nnkDerefExpr, syncCtxMyLib)
    let syncHelperCall = newTree(nnkCall, syncBodyProcName, syncLibValDeref)
    for name in extraParamNames:
      syncHelperCall.add(ident(name))

    let retValOrErrIdent = ident("retValOrErr")
    syncFfiBody.add quote do:
      let `retValOrErrIdent` = `syncHelperCall`
      if `retValOrErrIdent`.isErr():
        let errStr =
          if `retValOrErrIdent`.error.len > 0: `retValOrErrIdent`.error
          else: "unknown error"
        callback(
          RET_ERR, cast[ptr cchar](errStr.cstring), cast[csize_t](errStr.len), userData
        )
        return RET_ERR
      let encoded = cborEncode(`retValOrErrIdent`.value)
      if encoded.len > 0:
        callback(
          RET_OK, cast[ptr cchar](unsafeAddr encoded[0]),
          cast[csize_t](encoded.len), userData
        )
      else:
        var sentinel = CborNullByte
        callback(
          RET_OK, cast[ptr cchar](addr sentinel), 1.csize_t, userData
        )
      return RET_OK

    let syncFfiProc = newProc(
      name = postfix(cExportProcName, "*"),
      params = syncExportedParams,
      body = syncFfiBody,
      pragmas = newTree(
        nnkPragma,
        ident("dynlib"),
        newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
        ident("cdecl"),
        newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
      ),
    )

    block:
      var ffiExtraParamsSync: seq[FFIParamMeta] = @[]
      for i in 0 ..< extraParamNames.len:
        let ptype = extraParamTypes[i]
        let isPtr = ptype.kind == nnkPtrTy
        let tn =
          if isPtr: nimTypeNameRepr(ptype[0])
          else: nimTypeNameRepr(ptype)
        ffiExtraParamsSync.add(
          FFIParamMeta(name: extraParamNames[i], typeName: tn, isPtr: isPtr)
        )
      let retTypeInnerSync = resultInner[1]
      let retIsPtrSync = retTypeInnerSync.kind == nnkPtrTy
      let retTnSync =
        if retIsPtrSync: nimTypeNameRepr(retTypeInnerSync[0])
        else: nimTypeNameRepr(retTypeInnerSync)
      ffiProcRegistry.add(
        FFIProcMeta(
          procName: cExportName,
          libName: currentLibName,
          kind: FFIKind.FFI,
          libTypeName: $libTypeName,
          extraParams: ffiExtraParamsSync,
          returnTypeName: retTnSync,
          returnIsPtr: retIsPtrSync,
          isAsync: false,
        )
      )

    stmts = newStmtList(
      syncReqTypeDef, syncBodyProc, userAsyncWrapper, syncFfiProc
    )

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

# ---------------------------------------------------------------------------
# ffiCtor — constructor macro
# ---------------------------------------------------------------------------

proc buildCtorRequestType(reqTypeName: NimNode, paramNames: seq[string],
                          paramTypes: seq[NimNode]): NimNode =
  ## Builds the ctor's Req object using the user's actual Nim types.
  var fields: seq[NimNode] = @[]
  for i in 0 ..< paramNames.len:
    let fieldName = ident(paramNames[i])
    let storedType = fieldStorageType(paramTypes[i])
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

proc buildCtorFfiNewReqProc(
    reqTypeName: NimNode, paramNames: seq[string]
): NimNode =
  ## Wraps a CBOR byte buffer into an FFIThreadRequest for the ctor request type.

  var formalParams = newSeq[NimNode]()

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  formalParams.add(newIdentDefs(ident("userData"), ident("pointer")))
  formalParams.add(
    newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte")))
  )
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
    let `decodedIdent` =
      cborDecodePtr(
        cast[ptr UncheckedArray[byte]](`reqIdent`[].data),
        `reqIdent`[].dataLen,
        `reqTypeName`,
      ).valueOr:
        return err("CBOR decode failed for " & $T & ": " & $error)

  for i in 0 ..< paramNames.len:
    let paramIdent = ident(paramNames[i])
    let userType = paramTypes[i]
    let storedAsString =
      userType.kind == nnkIdent and $userType == "cstring"
    if storedAsString:
      newBody.add quote do:
        let `paramIdent`: cstring = (`decodedIdent`.`paramIdent`).cstring
    else:
      newBody.add quote do:
        let `paramIdent` = `decodedIdent`.`paramIdent`

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
  ## Defines a C-exported constructor. The generated wrapper takes a single
  ## CBOR-encoded request buffer covering all constructor parameters.

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
      paramNames.add($p[j])
      paramTypes.add(p[^2])

  let procNameStr = $procName
  let cleanName =
    if procNameStr.endsWith("*"):
      procNameStr[0 ..^ 2]
    else:
      procNameStr
  let cExportName = nimNameToCExport(cleanName)
  let reqTypeNameStr = snakeToPascalCase(cleanName) & "CtorReq"
  let reqTypeName = ident(reqTypeNameStr)

  let typeDef = buildCtorRequestType(reqTypeName, paramNames, paramTypes)
  let ffiNewReqProc = buildCtorFfiNewReqProc(reqTypeName, paramNames)
  # The user-facing Nim proc keeps the user's original name with their declared
  # signature; the C-exported wrapper moves to `<userProcName>ExportC` and
  # binds the snake_case C symbol via `{.exportc.}`.
  let userProcName =
    if procName.kind == nnkPostfix:
      procName[1]
    else:
      procName
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
  exportedParams.add(
    newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte")))
  )
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

  let ffiProc = newProc(
    name = postfix(cExportProcName, "*"),
    params = exportedParams,
    body = ffiBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cExportName)),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  block:
    var ctorExtraParams: seq[FFIParamMeta] = @[]
    for i in 0 ..< paramNames.len:
      let ptype = paramTypes[i]
      let isPtr = ptype.kind == nnkPtrTy
      let tn =
        if isPtr: nimTypeNameRepr(ptype[0])
        else: nimTypeNameRepr(ptype)
      ctorExtraParams.add(FFIParamMeta(name: paramNames[i], typeName: tn, isPtr: isPtr))
    ffiProcRegistry.add(
      FFIProcMeta(
        procName: cExportName,
        libName: currentLibName,
        kind: FFIKind.CTOR,
        libTypeName: $libTypeName,
        extraParams: ctorExtraParams,
        returnTypeName: $libTypeName,
        returnIsPtr: false,
        isAsync: true,
      )
    )

  let poolDecl = quote do:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts = newStmtList(
    typeDef, ffiNewReqProc, helperProc, processProc, addToReg, poolDecl,
    ffiProc,
  )

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

# ---------------------------------------------------------------------------
# ffiDtor — destructor macro (unchanged signature)
# ---------------------------------------------------------------------------

macro ffiDtor*(prc: untyped): untyped =
  ## Defines a C-exported destructor. Signature unchanged: takes ctx + cb + ud.

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("ffiDtor: proc must have exactly one parameter (w: LibType)")

  let libParamName = formalParams[1][0]
  let libTypeName = formalParams[1][1]

  let procNameStr = block:
    let raw = $procName
    if raw.endsWith("*"): raw[0 ..^ 2] else: raw
  let cExportName = nimNameToCExport(procNameStr)
  # The dtor only needs a C-exported wrapper; rename to a synthetic Nim ident
  # so it doesn't shadow the user's chosen name (consistent with .ffi. / .ffiCtor.).
  # The dtor only generates a C-exported wrapper; it uses the user's name
  # directly (no overload needed — there's no Nim-facing helper here).
  let cExportProcName =
    if procName.kind == nnkPostfix: procName[1] else: procName

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
    bodyNode.kind == nnkEmpty or
    (bodyNode.kind == nnkStmtList and bodyNode.len == 1 and
      bodyNode[0].kind == nnkDiscardStmt)
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
    params = @[
      ident("cint"),
      newIdentDefs(ident("ctx"), ident("pointer")),
    ],
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
      isAsync: false,
    )
  )

  let poolDecl = quote do:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts = newStmtList(poolDecl, ffiProc)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

# ---------------------------------------------------------------------------
# genBindings — codegen entry point
# ---------------------------------------------------------------------------

macro genBindings*(
    outputDir: static[string] = ffiOutputDir,
    nimSrcRelPath: static[string] = ffiNimSrcRelPath,
): untyped =
  ## Emits C++ or Rust binding files from the compile-time FFI registries.
  ## See plan: the foreign-side wrapper encodes one CBOR buffer per request.

  when defined(ffiGenBindings):
    if outputDir.len == 0:
      error(
        "genBindings: output directory is empty." &
        " Pass it as an argument or set -d:ffiOutputDir=path/to/output"
      )
    let lang = targetLang.toLowerAscii()
    let libName = deriveLibName(ffiProcRegistry)
    case lang
    of "rust":
      generateRustCrate(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath
      )
    of "cpp", "c++":
      generateCppBindings(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath
      )
    else:
      error("genBindings: unknown targetLang '" & lang & "'. Use 'rust' or 'cpp'.")

  return newEmptyNode()
