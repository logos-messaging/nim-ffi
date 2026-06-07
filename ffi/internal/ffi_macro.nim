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
  ## e.g. "nimtimerCreate" → "nimtimer_create", "nimtimer_echo" → "nimtimer_echo"
  for i, c in s:
    if c.isUpperAscii() and i > 0:
      result.add('_')
    result.add(c.toLowerAscii())

proc registerFfiTypeInfo(typeDef: NimNode): NimNode {.compileTime.} =
  ## Registers the type in ffiTypeRegistry for binding generation and returns
  ## the clean typeDef. Serialization is handled by the generic overloads in serial.nim.
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
  result = typeDef

proc cParamName(paramName: string, paramType: NimNode): string =
  ## C export parameter name. string params are passed as-is from C and need
  ## no Json suffix; other types carry Json to signal they require JSON encoding.
  if paramType.kind == nnkIdent and $paramType == "string":
    paramName
  else:
    paramName & "Json"

proc capitalizeFirstLetter(s: string): string =
  ## Returns `s` with the first character uppercased.
  if s.len == 0:
    return s
  result = s
  result[0] = s[0].toUpperAscii()

proc toCamelCase(s: string): string =
  ## Converts snake_case or mixed identifiers to CamelCase for type names.
  ## e.g. "testlib_create" -> "TestlibCreate"
  var parts = s.split('_')
  result = ""
  for p in parts:
    result.add capitalizeFirstLetter(p)

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

proc extractFieldsFromLambda(body: NimNode): seq[NimNode] =
  ## Extracts the fields (params) from the given lambda body, when using the registerReqFFI macro.
  ## e.g., for:
  ##   registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[Waku]):
  ##     proc(
  ##         configJson: cstring, appCallbacks: AppCallbacks
  ##     ): Future[Result[string, string]] {.async.} =
  ##       ...
  ## The extracted fields will be:
  ##   - configJson: cstring
  ##   - appCallbacks: AppCallbacks
  ## 

  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda proc, found: " & $procNode.kind

  let params = procNode[3] # parameters list
  result = @[]
  for p in params[1 .. ^1]: # skip return type
    result.add newIdentDefs(p[0], p[1])

  when defined(ffiDumpMacros):
    echo result.repr

proc buildRequestType(reqTypeName: NimNode, body: NimNode): NimNode =
  ## Builds:
  ## type <reqTypeName>* = object
  ##   <lambdaParam1Name>: <lambdaParam1Type>
  ##   ...
  ## e.g.:
  ## type CreateNodeRequest* = object
  ##     configJson: cstring
  ##     appCallbacks: AppCallbacks
  ## 

  var procNode = body
  if procNode.kind == nnkStmtList and procNode.len == 1:
    procNode = procNode[0]
  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda proc, found: " & $procNode.kind

  let params = procNode[3] # formal params of the lambda
  var fields: seq[NimNode] = @[]
  for p in params[1 .. ^1]: # skip return type at index 0
    let name = p[0]
    let typ = p[1]
    # Field must be nnkIdentDefs(name, type, defaultExpr)
    fields.add newTree(nnkIdentDefs, name, typ, newEmptyNode())

  # Wrap fields in a rec list
  let recList = newTree(nnkRecList, fields)

  # object type node: object [of?] [] [pragma?] recList
  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)

  # Export the type (CreateNodeRequest*)
  let typeName =
    if reqTypeName.kind == nnkPostfix:
      reqTypeName
    else:
      postfix(reqTypeName, "*")

  result =
    newNimNode(nnkTypeSection).add(newTree(nnkTypeDef, typeName, newEmptyNode(), objTy))

  when defined(ffiDumpMacros):
    echo result.repr

proc buildFfiNewReqProc(reqTypeName, body: NimNode): NimNode =
  ## Builds the ffiNewProc in charge of creating the FFIThreadRequest in shared memory.
  ## Then, a pointer to this request will be sent to the FFI thread for processing.
  ## e.g.:
  ## proc ffiNewReq*(T: typedesc[CreateNodeRequest]; callback: FFICallBack;
  ##                 userData: pointer; configJson: cstring;
  ##                 appCallbacks: AppCallbacks): ptr FFIThreadRequest =
  ##   var reqObj = createShared(T)
  ##   reqObj[].configJson = configJson.alloc()
  ##   reqObj[].appCallbacks = appCallbacks
  ##   let typeStr`gensym2866 = $T
  ##   var ret`gensym2866 = FFIThreadRequest.init(callback, userData,
  ##       typeStr`gensym2866.cstring, reqObj)
  ##   return ret`gensym2866
  ## 
  ## This should be invoked by the ffi consumer thread (generally, main thread.)
  ## Notice that the shared memory allocated by the main thread is freed by the FFI thread
  ## after processing the request.

  var formalParams = newSeq[NimNode]()

  var procNode: NimNode
  if body.kind == nnkStmtList and body.len == 1:
    procNode = body[0] # unwrap single statement
  else:
    procNode = body

  if procNode.kind != nnkLambda and procNode.kind != nnkProcDef:
    error "registerReqFFI expects a lambda definition. Found: " & $procNode.kind

  # T: typedesc[CreateNodeRequest]
  let typedescParam = newIdentDefs(
    ident("T"), # param name
    nnkBracketExpr.newTree(ident("typedesc"), reqTypeName), # typedesc[T]
  )
  formalParams.add(typedescParam)

  # Other fixed FFI params
  formalParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  formalParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  # Add original lambda params
  let procParams = procNode[3]
  for p in procParams[1 .. ^1]:
    formalParams.add(p)

  # Build `ptr FFIThreadRequest`
  let retType = newNimNode(nnkPtrTy)
  retType.add(ident("FFIThreadRequest"))

  formalParams = @[retType] & formalParams

  # Build body
  let reqObjIdent = ident("reqObj")
  var newBody = newStmtList()
  newBody.add(
    quote do:
      var `reqObjIdent` = createShared(T)
  )

  for p in procParams[1 .. ^1]:
    let fieldNameIdent = ident($p[0])
    let fieldTypeNode = p[1]

    # Extract type name as string
    var typeStr: string
    if fieldTypeNode.kind == nnkIdent:
      typeStr = $fieldTypeNode
    elif fieldTypeNode.kind == nnkBracketExpr:
      typeStr = $fieldTypeNode[0] # e.g., `ptr` in `ptr[Waku]`
    else:
      typeStr = "" # fallback

    # Apply .alloc() only to cstrings
    if typeStr == "cstring":
      newBody.add(
        quote do:
          `reqObjIdent`[].`fieldNameIdent` = `fieldNameIdent`.alloc()
      )
    else:
      newBody.add(
        quote do:
          `reqObjIdent`[].`fieldNameIdent` = `fieldNameIdent`
      )

  # FFIThreadRequest.init using fnv1aHash32
  newBody.add(
    quote do:
      let typeStr = $T
      var ret =
        FFIThreadRequest.init(callback, userData, typeStr.cstring, `reqObjIdent`)
      proc destroyContent(content: pointer) {.nimcall.} =
        ffiDeleteReq(cast[ptr `reqTypeName`](content))

      ret[].deleteReqContent = destroyContent
      return ret
  )

  # Build the proc node
  result = newProc(
    name = postfix(ident("ffiNewReq"), "*"),
    params = formalParams,
    body = newBody,
    pragmas = newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo result.repr

proc buildFfiDeleteReqProc(reqTypeName: NimNode, fields: seq[NimNode]): NimNode =
  ## Generates:
  ## proc ffiDeleteReq(self: ptr <reqTypeName>) =
  ##   deallocShared(self[].<cstringField>)
  ##   deallocShared(self)

  # Build the body
  var body = newStmtList()
  for f in fields:
    if $f[1] == "cstring": # only dealloc cstring fields
      body.add newCall(
        ident("deallocShared"),
        newDotExpr(newTree(nnkDerefExpr, ident("self")), ident($f[0])),
      )

  # Always free the whole object at the end
  body.add newCall(ident("deallocShared"), ident("self"))

  # Build the parameter: (self: ptr <reqTypeName>)
  let selfParam = newIdentDefs(ident("self"), newTree(nnkPtrTy, reqTypeName))

  # Build the proc definition
  result = newProc(
    name = postfix(ident("ffiDeleteReq"), "*"),
    params = @[newEmptyNode()] & @[selfParam], # ✅ properly wrapped in a sequence
    body = body,
  )

  when defined(ffiDumpMacros):
    echo result.repr

proc buildProcessFFIRequestProc(reqTypeName, reqHandler, body: NimNode): NimNode =
  ## Builds, f.e.:
  ## proc processFFIRequest(T: typedesc[CreateNodeRequest];
  ##                        configJson: cstring;
  ##                        appCallbacks: AppCallbacks;
  ##                        ctx: ptr FFIContext[Waku]) ...

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

  # Build formal params: (returnType, request: pointer, waku: ptr Waku)
  let procParams = procNode[3]
  var formalParams: seq[NimNode] = @[]
  formalParams.add(procParams[0]) # return type
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("request"), ident("pointer")))
  formalParams.add(newIdentDefs(reqHandler[0], rhs)) # e.g. waku: ptr Waku

  # Inject cast/unpack/defer into the body
  let bodyNode =
    if procNode.body.kind == nnkStmtList:
      procNode.body
    else:
      newStmtList(procNode.body)

  let newBody = newStmtList()
  let reqIdent = genSym(nskLet, "req")

  newBody.add quote do:
    let `reqIdent`: ptr `reqTypeName` = cast[ptr `reqTypeName`](request)

  # automatically unpack fields into locals
  for p in procParams[1 ..^ 1]:
    let fieldName = p[0] # Ident

    newBody.add quote do:
      let `fieldName` = `reqIdent`[].`fieldName`

  # Append user's lambda body
  newBody.add(bodyNode)

  result = newProc(
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
    echo result.repr

proc addNewRequestToRegistry(reqTypeName, reqHandler: NimNode): NimNode =
  ## Adds a new request to the registeredRequests table.
  ## The key is a representation of the request, e.g. "CreateNodeReq".
  ## The value is a proc definition in charge of handling the request from FFI thread.

  # Build: request[].reqContent
  let reqContent =
    newDotExpr(newTree(nnkDerefExpr, ident("request")), ident("reqContent"))

  # Build Future[Result[string, string]] return type
  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), ident("string"), ident("string")),
  )

  # Extract the type from reqHandler (generic: ptr Waku, ptr Foo, ptr Bar, etc.)
  let rhsType =
    if reqHandler.kind == nnkExprColonExpr:
      reqHandler[1] # Use the explicit type
    else:
      error "Second argument must be a typed parameter, e.g. waku: ptr Waku"

  # Build: cast[ptr Waku](reqHandler) or cast[ptr Foo](reqHandler) dynamically
  let castedHandler = newTree(
    nnkCast,
    rhsType, # The type, e.g. ptr Waku
    ident("reqHandler"), # The expression to cast
  )

  let callExpr = newCall(
    newDotExpr(reqTypeName, ident("processFFIRequest")), ident("request"), castedHandler
  )

  var newBody = newStmtList()
  newBody.add(
    quote do:
      return await `callExpr`
  )

  # Build:
  # proc(request: pointer, reqHandler: pointer):
  #     Future[Result[string, string]] {.async.} =
  #   CreateNodeRequest.processFFIRequest(request, reqHandler)
  let asyncProc = newProc(
    name = newEmptyNode(), # anonymous proc
    params = @[
      returnType,
      newIdentDefs(ident("request"), ident("pointer")),
      newIdentDefs(ident("reqHandler"), ident("pointer")),
    ],
    body = newBody,
    pragmas = nnkPragma.newTree(ident("async")),
  )

  let reqTypeNameStr = $reqTypeName

  let key = newLit($reqTypeName)
  # Generate: registeredRequests["CreateNodeRequest"] = <generated proc>
  result =
    newAssignment(newTree(nnkBracketExpr, ident("registeredRequests"), key), asyncProc)

  when defined(ffiDumpMacros):
    echo result.repr

macro registerReqFFI*(reqTypeName, reqHandler, body: untyped): untyped =
  ## Registers a request that will be handled by the FFI/working thread.
  ## The request should be sent from the ffi consumer thread.
  ## 
  ## e.g.:
  ## In this example, we register a CreateNodeRequest that will be handled by a proc that contains
  ## the provided lambda body and parameters, by the FFI/working thread.
  ## 
  ## The lambda passed to this macro must:
  ##   - only have no-GC'ed types.
  ##   - Return Future[Result[string, string]] and be annotated with {.async.}
  ##     And notice that the returned values will be sent back to the ffi consumer thread.
  ## 
  ## registerReqFFI(CreateNodeRequest, ctx: ptr FFIContext[Waku]):
  ##   proc(
  ##       configJson: cstring, appCallbacks: AppCallbacks
  ##   ): Future[Result[string, string]] {.async.} =
  ##     ctx.myLib[] = (await createWaku(configJson, cast[AppCallbacks](appCallbacks))).valueOr:
  ##       return err($error)
  ##     return ok("")
  ## 
  ## On the other hand, the created FFI request should be dispatched from the ffi consumer thread
  ## (generally, the main thread) following something like:
  ## 
  ## ffi.sendRequestToFFIThread(
  ##     ctx, CreateNodeRequest.ffiNewReq(callback, userData, configJson, appCallbacks)
  ##   ).isOkOr:
  ##   ...
  ## ...
  ## 

  # Extract lambda params to generate fields
  let fields = extractFieldsFromLambda(body)

  let typeDef = buildRequestType(reqTypeName, body)
  let ffiNewReqProc = buildFfiNewReqProc(reqTypeName, body)
  let processProc = buildProcessFFIRequestProc(reqTypeName, reqHandler, body)
  let addNewReqToReg = addNewRequestToRegistry(reqTypeName, reqHandler)
  let deleteProc = buildFfiDeleteReqProc(reqTypeName, fields)
  result = newStmtList(typeDef, deleteProc, ffiNewReqProc, processProc, addNewReqToReg)

  when defined(ffiDumpMacros):
    echo result.repr

macro processReq*(
    reqType, ctx, callback, userData: untyped, args: varargs[untyped]
): untyped =
  ## Expands T.processReq(ctx, callback, userData, a, b, ...)
  ## e.g.:
  ##   waku_dial_peerReq.processReq(ctx, callback, userData, peerMultiAddr, protocol, timeoutMs)
  ## 

  var callArgs = @[reqType, callback, userData]
  for a in args:
    callArgs.add a

  let newReqCall = newCall(ident("ffiNewReq"), callArgs)

  let sendCall = newCall(
    newDotExpr(ident("ffi_context"), ident("sendRequestToFFIThread")), ctx, newReqCall
  )

  result = quote:
    block:
      let res = `sendCall`
      if res.isErr():
        let msg = "error in sendRequestToFFIThread: " & res.error
        `callback`(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), `userData`)
        return RET_ERR
      return RET_OK

  when defined(ffiDumpMacros):
    echo result.repr

macro ffiRaw*(prc: untyped): untyped =
  ## Defines an FFI-exported proc that registers a request handler to be executed
  ## asynchronously in the FFI thread.
  ##
  ## This is the "raw" / legacy form of the macro where the developer writes
  ## the ctx, callback, and userData parameters explicitly.
  ##
  ## {.ffiRaw.} implicitly implies: ...Return[Future[Result[string, string]] {.async.}
  ##
  ## When using {.ffiRaw.}, the first three parameters must be:
  ##  - ctx: ptr FFIContext[T]  <-- T is the type that handles the FFI requests
  ##  - callback: FFICallBack
  ##  - userData: pointer
  ## Then, additional parameters may be defined as needed, after these first three, always
  ## considering that only no-GC'ed (or C-like) types are allowed.
  ##
  ## e.g.:
  ## proc waku_version(
  ##     ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
  ## ) {.ffiRaw.} =
  ##   return ok(WakuNodeVersionString)
  ##

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("`.ffiRaw.` procs require at least 1 parameter")

  let firstParam = formalParams[1]
  let paramIdent = firstParam[0]
  let paramType = firstParam[1]

  # The first param of an `.ffiRaw.` proc is `ctx: ptr FFIContext[LibType]`.
  # Extract LibType so we can call the module-level pool var (named
  # "<LibType>FFIPool", declared by `.ffiCtor.`) to validate ctx.
  let libTypeName = paramType[0][1]
  let poolIdent = ident($libTypeName & "FFIPool")

  let reqName = ident($procName & "Req")
  let returnType = ident("cint")

  # Build parameter list (skip return type)
  var newParams = newSeq[NimNode]()
  newParams.add(returnType)
  for i in 1 ..< formalParams.len:
    newParams.add(newIdentDefs(formalParams[i][0], formalParams[i][1]))

  # Build Future[Result[string, string]] return type
  let futReturnType = quote:
    Future[Result[string, string]]

  var userParams = newSeq[NimNode]()
  userParams.add(futReturnType)
  if formalParams.len > 3:
    for i in 4 ..< formalParams.len:
      userParams.add(newIdentDefs(formalParams[i][0], formalParams[i][1]))

  # Build argument list for processReq
  var argsList = newSeq[NimNode]()
  for i in 1 ..< formalParams.len:
    argsList.add(formalParams[i][0])

  # 1. Build the dot expression. e.g.: waku_is_onlineReq.processReq
  let dotExpr = newTree(nnkDotExpr, reqName, ident"processReq")

  # 2. Build the call node with dotExpr as callee
  let callNode = newTree(nnkCall, dotExpr)
  for arg in argsList:
    callNode.add(arg)

  # Proc body
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
    name = newEmptyNode(), # anonymous proc
    params = userParams,
    body = newStmtList(bodyNode),
    pragmas = newTree(nnkPragma, ident"async"),
  )

  # registerReqFFI wrapper
  let registerReq = quote:
    registerReqFFI(`reqName`, `paramIdent`: `paramType`):
      `anonymousProcNode`

  result = newStmtList(registerReq, ffiProc)

  when defined(ffiDumpMacros):
    echo result.repr

macro ffi*(prc: untyped): untyped =
  ## Simplified FFI macro — applies to procs or types.
  ##
  ## On a type: `type Foo {.ffi.} = object` registers Foo for binding generation
  ## and generates ffiSerialize/ffiDeserialize overloads.
  ##
  ## On a proc: the annotated proc must have a first parameter of the library type,
  ## optionally additional Nim-typed parameters, and return Future[Result[RetType, string]].
  ## It must NOT include ctx, callback, or userData in its signature.
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
    return registerFfiTypeInfo(cleanTypeDef)

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  # Need at least the library param
  if formalParams.len < 2:
    error("`.ffi.` procs require at least 1 parameter (the library type)")

  # Extract LibType from the first parameter
  let firstParam = formalParams[1]
  let libParamName = firstParam[0] # e.g. `w`
  let libTypeName = firstParam[1] # e.g. `Waku`

  # Extract the return type: Future[Result[RetType, string]]
  # RetType is used in the body helper proc signature
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
  let resultInner = retTypeNode[1] # Result[RetType, string]
  if resultInner.kind != nnkBracketExpr or $resultInner[0] != "Result":
    error(
      "`.ffi.` return type must be Future[Result[RetType, string]], got: " &
        retTypeNode.repr
    )

  # Collect additional param names and types (everything after the first param)
  var extraParamNames: seq[string] = @[]
  var extraParamTypes: seq[NimNode] = @[]
  for i in 2 ..< formalParams.len:
    let p = formalParams[i]
    for j in 0 ..< p.len - 2:
      extraParamNames.add($p[j])
      extraParamTypes.add(p[^2])

  # Generate type/proc names from proc name
  let procNameStr = block:
    let raw = $procName
    if raw.endsWith("*"):
      raw[0 ..^ 2]
    else:
      raw
  let cExportName = nimNameToCExport(procNameStr)
  let camelName = toCamelCase(procNameStr)

  # Names of generated things
  let reqTypeName = ident(camelName & "Req")
  let helperProcName = ident(camelName & "Body")

  # Determine whether the body uses async operations
  let isAsync = bodyHasAwait(bodyNode)

  # Strip the * from the exported proc name (needed for both branches)
  let exportedProcName =
    if procName.kind == nnkPostfix:
      procName[1]
    else:
      procName

  # Common exported params (needed for both branches)
  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  if isAsync:
    # -------------------------------------------------------------------------
    # ASYNC PATH — existing behavior
    # -------------------------------------------------------------------------

    # -------------------------------------------------------------------------
    # 1. Named async helper proc containing the user body
    # -------------------------------------------------------------------------
    # proc MyLibSendBody*(w: Waku, cfg: SendConfig): Future[Result[RetType, string]] {.async.} =
    #   <user body>
    var helperParams = newSeq[NimNode]()
    helperParams.add(retTypeNode)
    # First param: w: LibType (by value, not pointer)
    helperParams.add(newIdentDefs(libParamName, libTypeName))
    for i in 0 ..< extraParamNames.len:
      helperParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))

    let helperProc = newProc(
      name = postfix(helperProcName, "*"),
      params = helperParams,
      body = newStmtList(bodyNode),
      pragmas = newTree(nnkPragma, ident("async")),
    )

    # -------------------------------------------------------------------------
    # 2. registerReqFFI call
    # -------------------------------------------------------------------------
    let futStrStr = nnkBracketExpr.newTree(
      ident("Future"),
      nnkBracketExpr.newTree(ident("Result"), ident("string"), ident("string")),
    )

    let ctxHandlerName = ident("ffiCtxHandler")
    let ptrFfiCtx =
      nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

    var lambdaParams = newSeq[NimNode]()
    lambdaParams.add(futStrStr)
    for i in 0 ..< extraParamNames.len:
      lambdaParams.add(
        newIdentDefs(ident(cParamName(extraParamNames[i], extraParamTypes[i])), ident("cstring"))
      )

    let lambdaBody = newStmtList()

    for i in 0 ..< extraParamNames.len:
      let cIdent = ident(cParamName(extraParamNames[i], extraParamTypes[i]))
      let paramIdent = ident(extraParamNames[i])
      let ptype = extraParamTypes[i]
      if $cIdent != $paramIdent:
        # Non-string param: cIdent has a Json suffix. Deserialize into paramIdent.
        # buildProcessFFIRequestProc unpacks cIdent from the req struct, so no name clash.
        lambdaBody.add quote do:
          let `paramIdent` = ffiDeserialize(`cIdent`, `ptype`).valueOr:
            return err($error)
      # String params (cIdent == paramIdent): buildProcessFFIRequestProc already
      # unpacks the cstring under the same name; we convert inline in the helperCall below.

    let ctxMyLib = newDotExpr(newTree(nnkDerefExpr, ctxHandlerName), ident("myLib"))
    let libValDeref = newTree(nnkDerefExpr, ctxMyLib)
    let helperCall = newTree(nnkCall, helperProcName, libValDeref)
    for i in 0 ..< extraParamNames.len:
      let cIdent = ident(cParamName(extraParamNames[i], extraParamTypes[i]))
      let paramIdent = ident(extraParamNames[i])
      if $cIdent == $paramIdent:
        # String param: cIdent/paramIdent is the cstring from the req unpack;
        # convert to string with $ (ffiDeserialize for string is just ok($s)).
        helperCall.add(newCall(ident("$"), paramIdent))
      else:
        helperCall.add(paramIdent)

    let retValIdent = ident("retVal")
    lambdaBody.add quote do:
      let `retValIdent` = (await `helperCall`).valueOr:
        return err($error)
    lambdaBody.add quote do:
      return ok(ffiSerialize(`retValIdent`))

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
    # 3. C-exported proc (async path)
    # -------------------------------------------------------------------------
    var exportedParams = newSeq[NimNode]()
    exportedParams.add(ident("cint"))
    exportedParams.add(newIdentDefs(ident("ctx"), ctxType))
    exportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
    exportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))
    for i in 0 ..< extraParamNames.len:
      exportedParams.add(
        newIdentDefs(ident(cParamName(extraParamNames[i], extraParamTypes[i])), ident("cstring"))
      )

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

    let newReqCall = newTree(nnkCall, ident("ffiNewReq"))
    newReqCall.add(reqTypeName)
    newReqCall.add(ident("callback"))
    newReqCall.add(ident("userData"))
    for i in 0 ..< extraParamNames.len:
      newReqCall.add(ident(cParamName(extraParamNames[i], extraParamTypes[i])))

    let sendCall = newCall(
      newDotExpr(ident("ffi_context"), ident("sendRequestToFFIThread")),
      ident("ctx"),
      newReqCall,
    )

    let sendResIdent = genSym(nskLet, "sendRes")
    ffiBody.add quote do:
      let `sendResIdent` =
        try:
          `sendCall`
        except Exception as exc:
          Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
      if `sendResIdent`.isErr():
        let errStr = "error in sendRequestToFFIThread: " & `sendResIdent`.error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR
      return RET_OK

    let ffiProc = newProc(
      name = exportedProcName,
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

    # Register proc metadata for binding generation
    block:
      var ffiExtraParams: seq[FFIParamMeta] = @[]
      for i in 0 ..< extraParamNames.len:
        let ptype = extraParamTypes[i]
        var isPtr = false
        var tn = ""
        if ptype.kind == nnkPtrTy:
          isPtr = true
          tn = $ptype[0]
        else:
          tn = $ptype
        ffiExtraParams.add(
          FFIParamMeta(name: extraParamNames[i], typeName: tn, isPtr: isPtr)
        )
      let retTypeInner = resultInner[1] # RetType from Result[RetType, string]
      var retIsPtr = false
      var retTn = ""
      if retTypeInner.kind == nnkPtrTy:
        retIsPtr = true
        retTn = $retTypeInner[0]
      else:
        retTn = $retTypeInner
      ffiProcRegistry.add(
        FFIProcMeta(
          procName: cExportName,
          libName: currentLibName,
          kind: ffiFfiKind,
          libTypeName: $libTypeName,
          extraParams: ffiExtraParams,
          returnTypeName: retTn,
          returnIsPtr: retIsPtr,
          isAsync: true,
        )
      )

    result = newStmtList(helperProc, registerReq, ffiProc)
  else:
    # -------------------------------------------------------------------------
    # SYNC PATH — no await/waitFor in body; bypass thread-channel machinery
    # -------------------------------------------------------------------------

    # -------------------------------------------------------------------------
    # 1. Named sync helper proc (no {.async.}) with Result[RetType, string] return
    # -------------------------------------------------------------------------
    # proc MyLibVersionBody*(w: LibType): Result[RetType, string] =
    #   <user body>
    let syncRetType = resultInner # Result[RetType, string]

    var syncHelperParams = newSeq[NimNode]()
    syncHelperParams.add(syncRetType)
    syncHelperParams.add(newIdentDefs(libParamName, libTypeName))
    for i in 0 ..< extraParamNames.len:
      syncHelperParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))

    let syncHelperProc = newProc(
      name = postfix(helperProcName, "*"),
      params = syncHelperParams,
      body = newStmtList(bodyNode),
      pragmas = newEmptyNode(),
    )

    # -------------------------------------------------------------------------
    # 2. C-exported proc (sync path) — calls helper inline, fires callback inline
    # -------------------------------------------------------------------------
    var syncExportedParams = newSeq[NimNode]()
    syncExportedParams.add(ident("cint"))
    syncExportedParams.add(newIdentDefs(ident("ctx"), ctxType))
    syncExportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
    syncExportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))
    for i in 0 ..< extraParamNames.len:
      syncExportedParams.add(
        newIdentDefs(ident(cParamName(extraParamNames[i], extraParamTypes[i])), ident("cstring"))
      )

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

    # Inline deserialization of each extra param
    for i in 0 ..< extraParamNames.len:
      let cIdent = ident(cParamName(extraParamNames[i], extraParamTypes[i]))
      let paramIdent = ident(extraParamNames[i])
      let ptype = extraParamTypes[i]
      syncFfiBody.add quote do:
        let `paramIdent` = ffiDeserialize(`cIdent`, `ptype`).valueOr:
          let errStr = "deserialization failed: " & $error
          callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
          return RET_ERR

    # Build the call to the sync helper: helperProcName(ctx[].myLib[], extraParam, ...)
    let syncCtxMyLib = newDotExpr(newTree(nnkDerefExpr, ident("ctx")), ident("myLib"))
    let syncLibValDeref = newTree(nnkDerefExpr, syncCtxMyLib)
    let syncHelperCall = newTree(nnkCall, helperProcName, syncLibValDeref)
    for name in extraParamNames:
      syncHelperCall.add(ident(name))

    let retValOrErrIdent = ident("retValOrErr")
    syncFfiBody.add quote do:
      let `retValOrErrIdent` = `syncHelperCall`
      if `retValOrErrIdent`.isErr():
        let errStr = `retValOrErrIdent`.error
        callback(
          RET_ERR, cast[ptr cchar](errStr.cstring), cast[csize_t](errStr.len), userData
        )
        return RET_ERR
      let serialized = ffiSerialize(`retValOrErrIdent`.value)
      callback(
        RET_OK, cast[ptr cchar](serialized.cstring), cast[csize_t](serialized.len), userData
      )
      return RET_OK

    let syncFfiProc = newProc(
      name = exportedProcName,
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

    # Register proc metadata for binding generation (sync path)
    block:
      var ffiExtraParamsSync: seq[FFIParamMeta] = @[]
      for i in 0 ..< extraParamNames.len:
        let ptype = extraParamTypes[i]
        var isPtr = false
        var tn = ""
        if ptype.kind == nnkPtrTy:
          isPtr = true
          tn = $ptype[0]
        else:
          tn = $ptype
        ffiExtraParamsSync.add(
          FFIParamMeta(name: extraParamNames[i], typeName: tn, isPtr: isPtr)
        )
      let retTypeInnerSync = resultInner[1]
      var retIsPtrSync = false
      var retTnSync = ""
      if retTypeInnerSync.kind == nnkPtrTy:
        retIsPtrSync = true
        retTnSync = $retTypeInnerSync[0]
      else:
        retTnSync = $retTypeInnerSync
      ffiProcRegistry.add(
        FFIProcMeta(
          procName: cExportName,
          libName: currentLibName,
          kind: ffiFfiKind,
          libTypeName: $libTypeName,
          extraParams: ffiExtraParamsSync,
          returnTypeName: retTnSync,
          returnIsPtr: retIsPtrSync,
          isAsync: false,
        )
      )

    result = newStmtList(syncHelperProc, syncFfiProc)

  when defined(ffiDumpMacros):
    echo result.repr

# ---------------------------------------------------------------------------
# ffiCtor — constructor macro
# ---------------------------------------------------------------------------

proc buildCtorRequestType(reqTypeName: NimNode, paramNames: seq[string]): NimNode =
  ## Builds the request object type for a ctor request.
  ## Each original Nim-typed param becomes a cstring field named <paramName>Json.
  ##
  ## e.g. type TestlibCreateCtorReq* = object
  ##        configJson: cstring
  var fields: seq[NimNode] = @[]
  for name in paramNames:
    let fieldName = ident(name & "Json")
    fields.add newTree(nnkIdentDefs, fieldName, ident("cstring"), newEmptyNode())

  let recList =
    if fields.len > 0:
      newTree(nnkRecList, fields)
    else:
      newTree(
        nnkRecList,
        newTree(nnkIdentDefs, ident("_placeholder"), ident("pointer"), newEmptyNode()),
      )

  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)
  let typeName = postfix(reqTypeName, "*")
  result =
    newNimNode(nnkTypeSection).add(newTree(nnkTypeDef, typeName, newEmptyNode(), objTy))

  when defined(ffiDumpMacros):
    echo result.repr

proc buildCtorDeleteReqProc(reqTypeName: NimNode, paramNames: seq[string]): NimNode =
  ## Generates ffiDeleteReq for the ctor request type.
  var body = newStmtList()
  for name in paramNames:
    let fieldName = ident(name & "Json")
    body.add newCall(
      ident("deallocShared"),
      newDotExpr(newTree(nnkDerefExpr, ident("self")), fieldName),
    )
  body.add newCall(ident("deallocShared"), ident("self"))

  let selfParam = newIdentDefs(ident("self"), newTree(nnkPtrTy, reqTypeName))
  result = newProc(
    name = postfix(ident("ffiDeleteReq"), "*"),
    params = @[newEmptyNode()] & @[selfParam],
    body = body,
  )

  when defined(ffiDumpMacros):
    echo result.repr

proc buildCtorFfiNewReqProc(reqTypeName: NimNode, paramNames: seq[string]): NimNode =
  ## Generates ffiNewReq for the ctor request type.
  ## Params: T: typedesc[CtorReq], callback: FFICallBack, userData: pointer,
  ##         <paramName>Json: cstring, ...

  var formalParams = newSeq[NimNode]()

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  formalParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  for name in paramNames:
    formalParams.add(newIdentDefs(ident(name & "Json"), ident("cstring")))

  let retType = newTree(nnkPtrTy, ident("FFIThreadRequest"))
  formalParams = @[retType] & formalParams

  let reqObjIdent = ident("reqObj")
  var newBody = newStmtList()
  newBody.add quote do:
    var `reqObjIdent` = createShared(T)

  for name in paramNames:
    let fieldName = ident(name & "Json")
    newBody.add quote do:
      `reqObjIdent`[].`fieldName` = `fieldName`.alloc()

  newBody.add quote do:
    let typeStr = $T
    var ret = FFIThreadRequest.init(callback, userData, typeStr.cstring, `reqObjIdent`)
    proc destroyContent(content: pointer) {.nimcall.} =
      ffiDeleteReq(cast[ptr `reqTypeName`](content))

    ret[].deleteReqContent = destroyContent
    return ret

  result = newProc(
    name = postfix(ident("ffiNewReq"), "*"),
    params = formalParams,
    body = newBody,
    pragmas = newEmptyNode(),
  )

  when defined(ffiDumpMacros):
    echo result.repr

proc buildCtorBodyProc(
    helperName: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
    libTypeName: NimNode,
    userBody: NimNode,
): NimNode =
  ## Generates a named top-level async helper proc that contains the user body.
  ## e.g.:
  ## proc TestlibCreateCtorBody*(config: SimpleConfig): Future[Result[SimpleLib, string]] {.async.} =
  ##   return ok(SimpleLib(value: config.initialValue))

  let innerRetType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), libTypeName, ident("string")),
  )
  var innerParams = newSeq[NimNode]()
  innerParams.add(innerRetType)
  for i in 0 ..< paramNames.len:
    innerParams.add(newIdentDefs(ident(paramNames[i]), paramTypes[i]))

  result = newProc(
    name = postfix(helperName, "*"),
    params = innerParams,
    body = newStmtList(userBody),
    pragmas = newTree(nnkPragma, ident("async")),
  )

  when defined(ffiDumpMacros):
    echo result.repr

proc buildCtorProcessFFIRequestProc(
    reqTypeName: NimNode,
    helperName: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
    libTypeName: NimNode,
): NimNode =
  ## Generates the processFFIRequest proc for the ctor.
  ## The handler:
  ##   1. Unpacks cstring fields from the request
  ##   2. Deserializes each cstring to the Nim type
  ##   3. Calls the helper async proc to get Result[LibType, string]
  ##   4. Stores the result in ctx.myLib via createShared
  ##   5. Returns ok($cast[ByteAddress](ctx))

  # Build Future[Result[string, string]] return type
  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), ident("string"), ident("string")),
  )

  # The ctx param type: ptr FFIContext[LibType]
  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  let typedescParam =
    newIdentDefs(ident("T"), nnkBracketExpr.newTree(ident("typedesc"), reqTypeName))

  var formalParams: seq[NimNode] = @[]
  formalParams.add(returnType)
  formalParams.add(typedescParam)
  formalParams.add(newIdentDefs(ident("request"), ident("pointer")))
  formalParams.add(newIdentDefs(ident("ctx"), ctxType))

  # Build the proc body
  let newBody = newStmtList()
  let reqIdent = ident("req")
  let ctxIdent = ident("ctx")

  # Cast the request
  newBody.add quote do:
    let `reqIdent`: ptr `reqTypeName` = cast[ptr `reqTypeName`](request)

  # Unpack fields and deserialize each param
  for i in 0 ..< paramNames.len:
    let fieldName = ident(paramNames[i] & "Json")
    let paramName = ident(paramNames[i])
    let ptype = paramTypes[i]
    newBody.add quote do:
      let `fieldName` = `reqIdent`[].`fieldName`
    newBody.add quote do:
      let `paramName` = ffiDeserialize(`fieldName`, `ptype`).valueOr:
        return err($error)

  # Call the helper proc with deserialized params
  let helperCallNode = newTree(nnkCall, helperName)
  for name in paramNames:
    helperCallNode.add(ident(name))

  let libValIdent = ident("libVal")
  newBody.add quote do:
    let `libValIdent` = (await `helperCallNode`).valueOr:
      return err($error)

  # Store in ctx.myLib
  let myLibIdent = newDotExpr(newTree(nnkDerefExpr, ctxIdent), ident("myLib"))
  newBody.add quote do:
    `myLibIdent` = createShared(`libTypeName`)
    `myLibIdent`[] = `libValIdent`

  # Return context address as decimal string
  newBody.add quote do:
    return ok($cast[uint](`ctxIdent`))

  result = newProc(
    name = postfix(ident("processFFIRequest"), "*"),
    params = formalParams,
    body = newBody,
    procType = nnkProcDef,
    pragmas = newTree(nnkPragma, ident("async")),
  )

  when defined(ffiDumpMacros):
    echo result.repr

proc addCtorRequestToRegistry(reqTypeName, libTypeName: NimNode): NimNode =
  ## Registers the ctor request in the registeredRequests table.
  ## The handler casts reqHandler to ptr FFIContext[LibType] and calls processFFIRequest.

  let ctxType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

  let returnType = nnkBracketExpr.newTree(
    ident("Future"),
    nnkBracketExpr.newTree(ident("Result"), ident("string"), ident("string")),
  )

  let callExpr = newCall(
    newDotExpr(reqTypeName, ident("processFFIRequest")),
    ident("request"),
    newTree(nnkCast, ctxType, ident("reqHandler")),
  )

  var newBody = newStmtList()
  newBody.add quote do:
    return await `callExpr`

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
  result =
    newAssignment(newTree(nnkBracketExpr, ident("registeredRequests"), key), asyncProc)

  when defined(ffiDumpMacros):
    echo result.repr

macro ffiCtor*(prc: untyped): untyped =
  ## Defines a C-exported constructor that creates an FFIContext and populates
  ## ctx.myLib asynchronously in the FFI thread.
  ##
  ## The annotated proc must:
  ##   - Have Nim-typed parameters (they are automatically serialized to/from JSON)
  ##   - Return Future[Result[LibType, string]]
  ##   - NOT include ctx, callback, or userData in its signature
  ##
  ## Example:
  ##   proc mylib_create*(config: SimpleConfig): Future[Result[SimpleLib, string]] {.ffiCtor.} =
  ##     return ok(SimpleLib(value: config.initialValue))
  ##
  ## The generated C-exported proc will have the signature:
  ##   proc mylib_create(configJson: cstring, callback: FFICallBack,
  ##                     userData: pointer): pointer {.exportc, cdecl, raises: [].}
  ##
  ## Returns the context pointer synchronously; NULL on failure.
  ## The callback also fires when async initialization completes, passing the ctx
  ## address as a decimal string on success. The caller should hold the returned
  ## pointer and pass it to subsequent .ffi. calls.

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  # Extract LibType from return type: Future[Result[LibType, string]]
  let retTypeNode = formalParams[0]
  # retTypeNode should be Future[Result[LibType, string]]
  if retTypeNode.kind == nnkEmpty:
    error(
      "ffiCtor: proc must have an explicit return type Future[Result[LibType, string]]"
    )
  # retTypeNode: BracketExpr(Future, BracketExpr(Result, LibType, string))
  if retTypeNode.kind != nnkBracketExpr or $retTypeNode[0] != "Future":
    error(
      "ffiCtor: return type must be Future[Result[LibType, string]], got: " &
        retTypeNode.repr
    )
  let resultInner = retTypeNode[1] # Result[LibType, string]
  if resultInner.kind != nnkBracketExpr or $resultInner[0] != "Result":
    error(
      "ffiCtor: return type must be Future[Result[LibType, string]], got: " &
        retTypeNode.repr
    )
  let libTypeName = resultInner[1] # LibType

  # Collect param names and types (skip return type at index 0)
  var paramNames: seq[string] = @[]
  var paramTypes: seq[NimNode] = @[]
  for i in 1 ..< formalParams.len:
    let p = formalParams[i]
    # p is IdentDefs: [name, type, default]
    for j in 0 ..< p.len - 2: # handle multi-name identdefs
      paramNames.add($p[j])
      paramTypes.add(p[^2])

  # Generate ctor request type name: <ProcNameCamelCase>CtorReq
  let procNameStr = $procName
  # Strip trailing * if exported
  let cleanName =
    if procNameStr.endsWith("*"):
      procNameStr[0 ..^ 2]
    else:
      procNameStr
  let cExportName = nimNameToCExport(cleanName)
  let reqTypeNameStr = toCamelCase(cleanName) & "CtorReq"
  let reqTypeName = ident(reqTypeNameStr)

  # Build constituent parts
  let typeDef = buildCtorRequestType(reqTypeName, paramNames)
  let deleteProc = buildCtorDeleteReqProc(reqTypeName, paramNames)
  let ffiNewReqProc = buildCtorFfiNewReqProc(reqTypeName, paramNames)
  # Helper proc name: e.g., TestlibCreateCtorReq -> TestlibCreateCtorBody
  let helperProcNameStr = reqTypeNameStr[0 ..^ ("CtorReq".len + 1)] & "CtorBody"
  let helperProcName = ident(helperProcNameStr)
  let helperProc =
    buildCtorBodyProc(helperProcName, paramNames, paramTypes, libTypeName, bodyNode)
  let processProc = buildCtorProcessFFIRequestProc(
    reqTypeName, helperProcName, paramNames, paramTypes, libTypeName
  )
  let addToReg = addCtorRequestToRegistry(reqTypeName, libTypeName)

  # Build the C-exported proc params:
  #   (<paramName>Json: cstring, ..., callback: FFICallBack, userData: pointer): pointer
  var exportedParams = newSeq[NimNode]()
  exportedParams.add(ident("pointer")) # return type: ctx pointer or nil on failure
  for name in paramNames:
    exportedParams.add(newIdentDefs(ident(name & "Json"), ident("cstring")))
  exportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  exportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  # Build the C-exported proc body
  let ffiBody = newStmtList()

  # initializeLibrary() — only if declared
  ffiBody.add quote do:
    when declared(initializeLibrary):
      initializeLibrary()

  # Use a gensym'd ctx identifier so both the let binding and usage match
  let ctxSym = genSym(nskLet, "ctx")

  # Module-level pool shared by ctor and dtor for this libType
  let poolIdent = ident($libTypeName & "FFIPool")

  # Create the FFIContext synchronously; return nil on failure
  ffiBody.add quote do:
    let `ctxSym` = `poolIdent`.createFFIContext().valueOr:
      if not callback.isNil:
        let errStr = "ffiCtor: failed to create FFIContext: " & $error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return nil

  # Deserialize each param for early validation
  for i in 0 ..< paramNames.len:
    let jsonIdent = ident(paramNames[i] & "Json")
    let ptype = paramTypes[i]
    ffiBody.add quote do:
      block:
        let validateRes = ffiDeserialize(`jsonIdent`, `ptype`)
        if validateRes.isErr():
          if not callback.isNil:
            let errStr = "ffiCtor: failed to deserialize param: " & $validateRes.error
            callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
          return nil

  # Build the ffiNewReq call with all cstring params
  var newReqArgs: seq[NimNode] = @[reqTypeName, ident("callback"), ident("userData")]
  for name in paramNames:
    newReqArgs.add(ident(name & "Json"))
  let newReqCall = newCall(ident("ffiNewReq"), newReqArgs)

  # sendRequestToFFIThread using the gensym'd ctx
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

  # Strip the * from proc name for the C exported version
  let exportedProcName =
    if procName.kind == nnkPostfix:
      procName[1] # the bare ident without *
    else:
      procName

  let ffiProc = newProc(
    name = exportedProcName,
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

  # Register metadata for binding generation (we're inside a macro = compile-time context)
  block:
    var ctorExtraParams: seq[FFIParamMeta] = @[]
    for i in 0 ..< paramNames.len:
      let ptype = paramTypes[i]
      var isPtr = false
      var tn = ""
      if ptype.kind == nnkPtrTy:
        isPtr = true
        tn = $ptype[0]
      else:
        tn = $ptype
      ctorExtraParams.add(FFIParamMeta(name: paramNames[i], typeName: tn, isPtr: isPtr))
    ffiProcRegistry.add(
      FFIProcMeta(
        procName: cExportName,
        libName: currentLibName,
        kind: ffiCtorKind,
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

  result = newStmtList(
    typeDef, deleteProc, ffiNewReqProc, helperProc, processProc, addToReg, poolDecl,
    ffiProc,
  )

  when defined(ffiDumpMacros):
    echo result.repr

# ---------------------------------------------------------------------------
# ffiDtor — destructor macro
# ---------------------------------------------------------------------------

macro ffiDtor*(prc: untyped): untyped =
  ## Defines a C-exported destructor. Works like {.ffi.} but also tears down
  ## the FFIContext after the body runs.
  ##
  ## The annotated proc must have exactly one parameter of the library type.
  ## The body contains any library-level cleanup to run before context teardown.
  ##
  ## Example:
  ##   proc mylibobj_destroy*(obj: MyLibObj) {.ffiDtor.} =
  ##     obj.cleanup()
  ##
  ## The generated C-exported proc has the signature:
  ##   cint mylibobj_destroy(void* ctx, FfiCallback callback, void* userData)
  ##
  ## Recycle the context for reuse to keep fd usage bounded.
  ## NON-BLOCKING: returns RET_OK once accepted;
  ## the real outcome arrives via `callback`.

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("ffiDtor: proc must have exactly one parameter (w: LibType)")

  let libParamName = formalParams[1][0] # e.g. w
  let libTypeName = formalParams[1][1]  # e.g. MyLibObj

  let procNameStr = block:
    let raw = $procName
    if raw.endsWith("*"): raw[0 ..^ 2] else: raw
  let cExportName = nimNameToCExport(procNameStr)
  let exportedProcName =
    if procName.kind == nnkPostfix: procName[1] else: procName

  let releaseResIdent = genSym(nskLet, "destroyRes")

  let ffiBody = newStmtList()

  ffiBody.add quote do:
    when declared(initializeLibrary):
      initializeLibrary()

  ffiBody.add quote do:
    if ctx.isNil or cast[ptr FFIContext[`libTypeName`]](ctx)[].myLib.isNil:
      if not callback.isNil:
        let errStr = "context not initialized"
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return RET_ERR

  # Extract the library value so the user body can reference it by name
  ffiBody.add quote do:
    let `libParamName` = cast[ptr FFIContext[`libTypeName`]](ctx)[].myLib[]

  # Append the user body if it is not a bare discard
  let isNoop =
    bodyNode.kind == nnkEmpty or
    (bodyNode.kind == nnkStmtList and bodyNode.len == 1 and
      bodyNode[0].kind == nnkDiscardStmt)
  if not isNoop:
    ffiBody.add(bodyNode)

  let poolIdent = ident($libTypeName & "FFIPool")
  ffiBody.add quote do:
    let `releaseResIdent` = releaseFFIContext(
      cast[ptr FFIContext[`libTypeName`]](ctx), callback, userData
    )
    if `releaseResIdent`.isErr():
      if not callback.isNil():
        let errStr = "release failed: " & $`releaseResIdent`.error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return RET_ERR
    return RET_OK

  let ffiProc = newProc(
    name = exportedProcName,
    params = @[
      ident("cint"),
      newIdentDefs(ident("ctx"), ident("pointer")),
      newIdentDefs(ident("callback"), ident("FFICallBack")),
      newIdentDefs(ident("userData"), ident("pointer")),
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
      kind: ffiDtorKind,
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

  result = newStmtList(poolDecl, ffiProc)

  when defined(ffiDumpMacros):
    echo result.repr

# ---------------------------------------------------------------------------
# genBindings — Rust crate generator
# ---------------------------------------------------------------------------

macro genBindings*(
    outputDir: static[string] = ffiOutputDir,
    nimSrcRelPath: static[string] = ffiNimSrcRelPath,
): untyped =
  ## Emits C++ or Rust binding files from the compile-time FFI registries.
  ##
  ## PLACEMENT REQUIREMENT: genBindings() must be called AFTER every {.ffi.}
  ## and {.ffiCtor.} annotation in the compilation unit. Each pragma populates
  ## ffiProcRegistry and ffiTypeRegistry as the compiler expands the AST;
  ## calling genBindings() earlier produces incomplete bindings.
  ##
  ## In a single-file library, place it at the bottom of the file.
  ## In a multi-file library, import all sub-modules first and call
  ## genBindings() once at the bottom of the top-level compilation-root file.
  ##
  ## Supported languages (-d:targetLang): "rust" (default), "cpp".
  ## Output path and nim source path default to -d:ffiOutputDir and
  ## -d:ffiNimSrcRelPath, or can be passed as explicit arguments.
  ## This macro is a no-op unless -d:ffiGenBindings is set.
  ##
  ## This reads -d:ffiOutputDir, -d:ffiNimSrcRelPath, -d:targetLang from compile flags.
  ## 
  ## Example (all via compile flags):
  ##   genBindings()
  ##   # nim c -d:ffiGenBindings -d:targetLang=rust \
  ##   #        -d:ffiOutputDir=examples/nim_timer/rust_bindings \
  ##   #        -d:ffiNimSrcRelPath=../nim_timer.nim mylib.nim

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

  result = newEmptyNode()
