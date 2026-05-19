import std/[macros, tables, strutils]
import chronos
import ../ffi_types
import ../codegen/[meta, string_helpers]
import ./c_macro_helpers
when defined(ffiGenBindings):
  import ../codegen/rust
  import ../codegen/cpp
  import ../codegen/c
  import ../codegen/cddl

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
  ## cbor_serial.nim (CBOR target) or by the *_CWire companion type + its
  ## conversion procs (C target).
  ##
  ## When `ffiMode == "raw"`, the returned StmtList carries both the
  ## original user type *and* the cwire companion + procs. The CBOR target
  ## still receives just the user type wrapped in a section, so callers
  ## that don't need the wire form see no extra symbols.
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

  # The cwire companion types/procs cannot be emitted from a type-pragma
  # macro (Nim's macro contract returns a single TypeDef). They are instead
  # emitted in bulk from `genBindings()` so the user types are fully
  # registered before any cwire AST is built.
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
  ## Standard parameter list for the C-exported wrapper of a `.ffi.` proc.
  ## Both modes share the same prefix — `cint; ctx, callback, userData, …`
  ## — and differ only in the trailing request-payload params:
  ##
  ## CBOR (`-d:ffiMode=cbor`, the default):
  ##   (returns cint; ctx, callback, userData, reqCbor, reqCborLen)
  ##
  ## Raw / pure C (`-d:ffiMode=raw`):
  ##   (returns cint; ctx, callback, userData, req: ptr <ReqType_CWire>)
  ##
  ## The CBOR shape carries an opaque byte-buffer payload; the raw shape
  ## mirrors the C struct emitted by ffi/codegen/c.nim so callers of the
  ## generated `<lib>.h` see a flat C-typed parameter list. The actual
  ## wire-payload params are appended by the caller (they vary per proc),
  ## so this helper just emits the leading prefix.
  var params: seq[NimNode] = @[]
  params.add(ident("cint"))
  params.add(newIdentDefs(ident("ctx"), ctxType))
  params.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  params.add(newIdentDefs(ident("userData"), ident("pointer")))
  params.add(newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte"))))
  params.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))
  return params

proc cTargetExportedParams(ctxType, reqWireType: NimNode): seq[NimNode] =
  ## Raw-mode variant of `cExportedParams`. `reqWireType` is the Nim wire
  ## type whose layout matches the C `<ReqType>` struct emitted by c.nim.
  ## Trailing `req` keeps the leading prefix identical to the CBOR shape.
  var params: seq[NimNode] = @[]
  params.add(ident("cint"))
  params.add(newIdentDefs(ident("ctx"), ctxType))
  params.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
  params.add(newIdentDefs(ident("userData"), ident("pointer")))
  params.add(newIdentDefs(ident("req"), nnkPtrTy.newTree(reqWireType)))
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
  ##
  ## CBOR target: decodes the CBOR payload into a Req struct via
  ## `cborDecodePtr`, unpacks each field into a local, then runs the user
  ## lambda body.
  ##
  ## C target: `data` is a `ptr <ReqType>_CWire` (deep-copied into shared
  ## memory by the exportc shim). The processor casts it back, calls
  ## `cwireUnpack` to obtain a natural Nim `<ReqType>` value, and unpacks
  ## from there. CBOR is never invoked on this path.

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

  if isPureCMode():
    let wireTypeName = ident(cwireTypeName($reqTypeName))
    newBody.add quote do:
      let `reqIdent`: ptr FFIThreadRequest = cast[ptr FFIThreadRequest](request)
      let `decodedIdent` = cwireUnpack(cast[ptr `wireTypeName`](`reqIdent`[].data)[])
  else:
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

proc addNewRequestToRegistry(
    reqTypeName, reqHandler: NimNode, respTypeName: NimNode = nil
): NimNode =
  ## Generates the dispatcher that the FFI thread calls: it invokes
  ## processFFIRequest (which returns the user's typed Result[T, string]) and
  ## encodes the success path appropriately for the active target.
  ##
  ## CBOR target: the success value goes through `cborEncode` so the
  ## consumer's wrapper can decode it on the other side.
  ##
  ## C target: the value is wrapped in a `<RespType>_CWire` envelope
  ## allocated in shared memory, the request envelope's cleanup hooks are
  ## set to free that envelope after the callback fires, and the returned
  ## seq[byte] is a struct snapshot whose pointer fields stay valid until
  ## handleRes runs the cleanup hook. `respTypeName` (non-nil only for the
  ## C target) names the synthesised response type, e.g. `MyTimerEchoResp`.

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

  if isPureCMode() and not respTypeName.isNil:
    let wireRespName = ident(cwireTypeName($respTypeName))
    let thunkName = ident("cwireFreePtr_" & $respTypeName)
    newBody.add quote do:
      let `typedResIdent` = await `callExpr`
      if `typedResIdent`.isErr:
        return err(`typedResIdent`.error)
      when typeof(`typedResIdent`.value) is void:
        return ok(newSeq[byte]())
      else:
        # Wrap in the synthesised <RespType> Nim envelope.
        let respObj = `respTypeName`(value: `typedResIdent`.value)
        # Allocate the wire envelope in shared memory and pack the value
        # (this strdup's any cstrings inside).
        let respWirePtr = cast[ptr `wireRespName`](allocShared(sizeof(`wireRespName`)))
        zeroMem(respWirePtr, sizeof(`wireRespName`))
        cwirePack(respWirePtr[], respObj)
        # Stash the cleanup pair on the request envelope so handleRes can
        # release shared memory *after* the foreign callback returns.
        let reqEnv = cast[ptr FFIThreadRequest](request)
        reqEnv[].cleanupRespData = cast[pointer](respWirePtr)
        reqEnv[].cleanupRespProc = `thunkName`
        # Hand a struct-byte snapshot to handleRes for the callback. The
        # pointers inside still reach into shared memory and remain valid
        # until cleanupRespProc runs.
        var bytes = newSeq[byte](sizeof(`wireRespName`))
        copyMem(unsafeAddr bytes[0], respWirePtr, sizeof(`wireRespName`))
        return ok(bytes)
  else:
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

  # Derive (per-proc) response wrapper type. For C target this wraps the
  # user's logical return value in a single-`value` envelope whose wire
  # form matches the C `<Proc>Resp` struct in the generated `<lib>.h`.
  proc derivedRespTypeName(reqName: string): string =
    if reqName.endsWith("CtorReq"):
      reqName[0 ..< reqName.len - 7] & "CtorResp"
    elif reqName.endsWith("Req"):
      reqName[0 ..< reqName.len - 3] & "Resp"
    else:
      reqName & "Resp"

  let respTypeNameStr = derivedRespTypeName($reqTypeName)
  let respTypeName = ident(respTypeNameStr)

  # Parse the lambda's return type → user's logical T. For
  # `Future[Result[T, string]]` we want T.
  var userRetType: NimNode = nil
  block:
    var procNode2 = body
    if procNode2.kind == nnkStmtList and procNode2.len == 1:
      procNode2 = procNode2[0]
    if procNode2.kind in {nnkLambda, nnkProcDef}:
      let rt = procNode2[3][0]
      if rt.kind == nnkBracketExpr and $rt[0] == "Future":
        let inner = rt[1]
        if inner.kind == nnkBracketExpr and $inner[0] == "Result":
          userRetType = inner[1]

  let isVoidReturn =
    userRetType.isNil or (userRetType.kind == nnkIdent and $userRetType == "void")

  let addNewReqToReg =
    if isPureCMode() and not isVoidReturn:
      addNewRequestToRegistry(reqTypeName, reqHandler, respTypeName)
    else:
      addNewRequestToRegistry(reqTypeName, reqHandler)

  # Order matters when targeting C: `processProc` (and any `.async` body
  # inside it) is sem-checked at macro-expansion time, so the wire type +
  # cwire conversion procs must already exist in the AST being returned.
  # The lay-out is:
  #   1. cwire sections for nested {.ffi.} types this Req depends on
  #   2. the user Req TypeSection
  #   3. the per-proc Req wire TypeSection
  #   4. per-proc Req cwire procs
  #   5. ffiNewReqProc / processProc / addNewReqToReg
  let stmts = newStmtList()

  if isPureCMode():
    var procNode = body
    if procNode.kind == nnkStmtList and procNode.len == 1:
      procNode = procNode[0]
    let lambdaParams = procNode[3]
    var paramNames: seq[string] = @[]
    var paramTypes: seq[NimNode] = @[]
    for p in lambdaParams[1 .. ^1]:
      paramNames.add($p[0])
      paramTypes.add(p[1])

    # 1. Dependencies first (idempotent across calls).
    var nestedDeps: seq[string] = @[]
    collectNestedFFITypes(paramTypes, nestedDeps)
    for dep in nestedDeps:
      ensureCWireFor(dep, stmts)

    # 2. User Req TypeSection.
    stmts.add(typeDef)

    # 3. Per-proc Req wire type in its own section so its references to
    #    dep wire types (already-emitted above) resolve.
    let wireSection = newNimNode(nnkTypeSection)
    wireSection.add(buildCWireTypeDef($reqTypeName, paramNames, paramTypes))
    stmts.add(wireSection)

    # 4. Per-proc Req cwire procs.
    for p in buildCWireProcs($reqTypeName, paramNames, paramTypes):
      stmts.add(p)

    # 5. Per-proc Resp envelope (Nim type with single `value` field) + its
    #    cwire companion + procs. Skipped when the user returns void.
    if not isVoidReturn:
      # Any nested ffi-types reachable via the return value need their
      # cwire emitted first (e.g. `value: EchoResponse` depends on
      # EchoResponse_CWire).
      var respNestedDeps: seq[string] = @[]
      collectNestedFFITypes(@[userRetType], respNestedDeps)
      for dep in respNestedDeps:
        ensureCWireFor(dep, stmts)

      # Resp Nim type: `type <ProcName>Resp = object\n  value: <T>`
      let respUserSection = newNimNode(nnkTypeSection)
      let respUserRecList =
        newTree(nnkRecList, newIdentDefs(ident("value"), userRetType, newEmptyNode()))
      respUserSection.add(
        newTree(
          nnkTypeDef,
          postfix(respTypeName, "*"),
          newEmptyNode(),
          newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), respUserRecList),
        )
      )
      stmts.add(respUserSection)

      # Resp wire type + procs.
      let respWireSection = newNimNode(nnkTypeSection)
      respWireSection.add(
        buildCWireTypeDef(respTypeNameStr, @["value"], @[userRetType])
      )
      stmts.add(respWireSection)
      for p in buildCWireProcs(respTypeNameStr, @["value"], @[userRetType]):
        stmts.add(p)
  else:
    stmts.add(typeDef)

  stmts.add(ffiNewReqProc)
  stmts.add(processProc)
  stmts.add(addNewReqToReg)

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
    # C-exported wrapper. Both shapes share the leading prefix
    # `(ctx, callback, userData, …): cint` and differ only in the trailing
    # request-payload params:
    #
    #   ffiMode=cbor (default):
    #     proc <name>(ctx, callback, userData, reqCbor, reqCborLen): cint
    #
    #   ffiMode=raw:
    #     proc <name>(ctx, callback, userData, req: ptr <ReqType>_CWire): cint
    #     The shim deep-copies the incoming wire Req into shared memory and
    #     dispatches via `initFromOwnedWirePtr` so the FFI thread can read
    #     the same struct without CBOR serialisation.
    # -------------------------------------------------------------------------
    let asyncPoolIdent = ident($libTypeName & "FFIPool")
    let wireTypeName = ident(cwireTypeName($reqTypeName))
    let thunkName = ident("cwireFreePtr_" & $reqTypeName)

    let exportedParams =
      if isPureCMode():
        cTargetExportedParams(ctxType, wireTypeName)
      else:
        cExportedParams(ctxType)

    let ffiBody = newStmtList()

    ffiBody.add quote do:
      if callback.isNil:
        return RET_MISSING_CALLBACK

    ffiBody.add quote do:
      if not `asyncPoolIdent`.isValidCtx(cast[pointer](ctx)):
        let errStr = "ctx is not a valid FFI context"
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return RET_ERR

    let reqPtrIdent = genSym(nskLet, "reqPtr")

    if isPureCMode():
      let sharedReqIdent = genSym(nskLet, "sharedReq")
      ffiBody.add quote do:
        if req.isNil:
          let errStr = "req pointer is nil"
          callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
          return RET_ERR
        let `sharedReqIdent` =
          cast[ptr `wireTypeName`](allocShared(sizeof(`wireTypeName`)))
        zeroMem(`sharedReqIdent`, sizeof(`wireTypeName`))
        cwirePack(`sharedReqIdent`[], cwireUnpack(req[]))
        let typeStr = $`reqTypeName`
        let `reqPtrIdent` = FFIThreadRequest.initFromOwnedWirePtr(
          callback,
          userData,
          typeStr.cstring,
          cast[pointer](`sharedReqIdent`),
          sizeof(`wireTypeName`),
          `thunkName`,
        )
    else:
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

    # Build the FFI metadata first so we can compute the ABI hash before
    # stamping the exportc name.
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

    # Content-addressable symbol versioning for the raw ABI. Any change
    # to the proc's canonical signature (param names/types, transitive
    # {.ffi.} type fields, return type) changes the hash and therefore
    # the exported symbol name — turning silent layout drift into a loud
    # "undefined symbol" link error. CBOR mode keeps clean symbol names
    # because its wire format already tolerates drift.
    var procAbiHash = ""
    var cSymbolName = cExportName
    if isPureCMode():
      procAbiHash = abiHashFor(cExportName, ffiExtraParams, retTn)
      cSymbolName = cExportName & "_v" & procAbiHash

    let ffiProc = newProc(
      name = postfix(cExportProcName, "*"),
      params = exportedParams,
      body = ffiBody,
      pragmas = newTree(
        nnkPragma,
        ident("dynlib"),
        newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(cSymbolName)),
        ident("cdecl"),
        newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
      ),
    )

    ffiProcRegistry.add(
      FFIProcMeta(
        procName: cExportName,
        libName: currentLibName,
        kind: FFIKind.FFI,
        libTypeName: $libTypeName,
        extraParams: ffiExtraParams,
        returnTypeName: retTn,
        returnIsPtr: retIsPtr,
        abiHash: procAbiHash,
      )
    )

    return newStmtList(helperProc, registerReq, ffiProc)

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

  if isPureCMode():
    let wireReqName = ident(cwireTypeName($reqTypeName))
    newBody.add quote do:
      let `reqIdent` = cast[ptr FFIThreadRequest](request)
      let `decodedIdent` = cwireUnpack(cast[ptr `wireReqName`](`reqIdent`[].data)[])
  else:
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
  ##
  ## CBOR target: encodes the ctx address (decimal string) as CBOR so the
  ## foreign-side wrapper can recover it via cbor decoding.
  ##
  ## C target: returns an empty payload — the synchronous return value of
  ## the exportc proc already conveys the ctx pointer, so the async
  ## callback just signals completion.

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
  if isPureCMode():
    newBody.add quote do:
      let `resIdent` = await `callExpr`
      if `resIdent`.isErr:
        return err(`resIdent`.error)
      # Sync return already delivered the ctx; nothing useful to ship to
      # the callback besides RET_OK.
      return ok(newSeq[byte]())
  else:
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

  # C-exported proc. CBOR target keeps the existing signature
  # (reqCbor, reqCborLen, callback, userData) → pointer. C target switches
  # to (ptr <ReqType>_CWire, callback, userData) → pointer so the host can
  # hand a flat C struct directly.
  let ctxSym = genSym(nskLet, "ctx")
  let poolIdent = ident($libTypeName & "FFIPool")
  let wireReqTypeName = ident(cwireTypeName($reqTypeName))
  let thunkName = ident("cwireFreePtr_" & $reqTypeName)

  var exportedParams = newSeq[NimNode]()
  exportedParams.add(ident("pointer"))
  if isPureCMode():
    exportedParams.add(newIdentDefs(ident("req"), nnkPtrTy.newTree(wireReqTypeName)))
    exportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
    exportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))
  else:
    exportedParams.add(newIdentDefs(ident("reqCbor"), nnkPtrTy.newTree(ident("byte"))))
    exportedParams.add(newIdentDefs(ident("reqCborLen"), ident("csize_t")))
    exportedParams.add(newIdentDefs(ident("callback"), ident("FFICallBack")))
    exportedParams.add(newIdentDefs(ident("userData"), ident("pointer")))

  let ffiBody = newStmtList()

  ffiBody.add quote do:
    when declared(initializeLibrary):
      initializeLibrary()

  ffiBody.add quote do:
    let `ctxSym` = `poolIdent`.createFFIContext().valueOr:
      if not callback.isNil:
        let errStr = "ffiCtor: failed to create FFIContext: " & $error
        callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
      return nil

  if isPureCMode():
    ffiBody.add quote do:
      if req.isNil:
        if not callback.isNil:
          let errStr = "ffiCtor: req pointer is nil"
          callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return nil
    let sharedReqIdent = genSym(nskLet, "sharedReq")
    let sendResIdent = genSym(nskLet, "sendRes")
    ffiBody.add quote do:
      let `sharedReqIdent` =
        cast[ptr `wireReqTypeName`](allocShared(sizeof(`wireReqTypeName`)))
      zeroMem(`sharedReqIdent`, sizeof(`wireReqTypeName`))
      cwirePack(`sharedReqIdent`[], cwireUnpack(req[]))
      let typeStr = $`reqTypeName`
      let `sendResIdent` =
        try:
          `ctxSym`.sendRequestToFFIThread(
            FFIThreadRequest.initFromOwnedWirePtr(
              callback,
              userData,
              typeStr.cstring,
              cast[pointer](`sharedReqIdent`),
              sizeof(`wireReqTypeName`),
              `thunkName`,
            )
          )
        except Exception as exc:
          Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
      if `sendResIdent`.isErr():
        if not callback.isNil:
          let errStr = "ffiCtor: failed to send request: " & $`sendResIdent`.error
          callback(RET_ERR, unsafeAddr errStr[0], cast[csize_t](errStr.len), userData)
        return nil
  else:
    # CBOR path (unchanged): validate the bytes parse, then dispatch.
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

  # Build the ctor's metadata before stamping the exportc name so we can
  # compute the ABI hash for `ffiMode=raw`.
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

  var ctorAbiHash = ""
  var ctorCSymbol = cExportName
  if isPureCMode():
    ctorAbiHash = abiHashFor(cExportName, ctorExtraParams, $libTypeName)
    ctorCSymbol = cExportName & "_v" & ctorAbiHash

  let ffiProc = newProc(
    name = postfix(cExportProcName, "*"),
    params = exportedParams,
    body = ffiBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      newTree(nnkExprColonExpr, ident("exportc"), newStrLitNode(ctorCSymbol)),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
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
      abiHash: ctorAbiHash,
    )
  )

  let poolDecl = quote:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts = newStmtList()
  if isPureCMode():
    # Same ordering rationale as `registerReqFFI`: emit nested-type cwires
    # first, then the user Req, then the per-Req wire type + procs, then
    # the rest of the ctor machinery.
    var nestedDeps: seq[string] = @[]
    collectNestedFFITypes(paramTypes, nestedDeps)
    for dep in nestedDeps:
      ensureCWireFor(dep, stmts)

    stmts.add(typeDef)

    let wireSection = newNimNode(nnkTypeSection)
    wireSection.add(buildCWireTypeDef($reqTypeName, paramNames, paramTypes))
    stmts.add(wireSection)
    for p in buildCWireProcs($reqTypeName, paramNames, paramTypes):
      stmts.add(p)
  else:
    stmts.add(typeDef)

  stmts.add(ffiNewReqProc)
  stmts.add(helperProc)
  stmts.add(processProc)
  stmts.add(addToReg)
  stmts.add(poolDecl)
  stmts.add(ffiProc)

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

  # Bind the user's library param so a non-trivial dtor body can reference
  # it. Tag `{.used.}` because dtors often leave the body as `discard` (or
  # only doc-comments + discard), which would otherwise trip XDeclaredButNotUsed.
  ffiBody.add quote do:
    let `libParamName` {.used.} = cast[ptr FFIContext[`libTypeName`]](ctx)[].myLib[]

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
      abiHash: "", # dtor signature is structurally invariant — no hash needed
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
# genBindings — codegen entry point
# ---------------------------------------------------------------------------

proc buildCWireExtrasForRegistry(): NimNode {.compileTime.} =
  ## Catch-all cwire emission. Each {.ffi.} type's cwire companion is
  ## normally produced lazily by the first `registerReqFFI` that references
  ## it (see `ensureCWireFor`). This call cleans up any orphan types that
  ## no proc happens to mention but that still appeared in user code, so
  ## the binding regeneration is exhaustive.
  result = newStmtList()
  if ffiTypeRegistry.len == 0:
    return result

  for tm in ffiTypeRegistry:
    ensureCWireFor(tm.name, result)

macro emitCWireExtras*(): untyped =
  ## Compile-time entry point: returns the AST of every `_CWire` type
  ## companion + its conversion procs derived from the populated
  ## `ffiTypeRegistry`. A no-op outside the C target so the macro is safe
  ## to call unconditionally from `genBindings`.
  if not isPureCMode():
    return newEmptyNode()
  return buildCWireExtrasForRegistry()

macro genBindings*(
    outputDir: static[string] = ffiOutputDir, nimSrcRelPath: static[string] = ffiSrcPath
): untyped =
  ## Emits binding files from the compile-time FFI registries, selected
  ## from the **2-axis target matrix**:
  ##
  ##   ffiMode  = c | cbor    (Nim-side ABI; default cbor)
  ##   ffiLang  = cpp | rust  (consumer-side wrapper language; default cpp)
  ##
  ## Legal cells:
  ##   (cbor, cpp)  — C++ wrapper using CBOR on the wire
  ##   (cbor, rust) — Rust crate using CBOR on the wire
  ##   (c,    cpp)  — C ABI header consumable by both C and C++ callers
  ##   (c,    rust) — Rust over pure-C ABI (NOT YET IMPLEMENTED)
  ##
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
  ## Output path and nim source path default to -d:ffiOutputDir and
  ## -d:ffiSrcPath, or can be passed as explicit arguments.
  ## Header/CMake generation is gated by -d:ffiGenBindings; the cwire
  ## companion types/procs (needed when ffiMode=raw) are emitted
  ## unconditionally so the generated shim is always linkable.

  when defined(ffiGenBindings):
    if outputDir.len == 0:
      error(
        "genBindings: output directory is empty." &
          " Pass it as an argument or set -d:ffiOutputDir=path/to/output"
      )
    let mode = effectiveMode()
    let lang = effectiveLang()
    let libName = deriveLibName(ffiProcRegistry)
    # `case` doesn't accept tuples; combine the two axes into a flat key.
    let cell = mode & "/" & lang
    case cell
    of "cbor/cpp":
      generateCppBindings(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath
      )
    of "cbor/rust":
      generateRustCrate(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath
      )
    of "cddl":
      generateCddlBindings(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath
      )
    of "raw/cpp":
      # The flat C-ABI cell. The emitted `.h` is `extern "C"`-safe so
      # it's directly consumable by both pure-C and C++ callers; the
      # dedicated C++-sugar `.hpp` layer over this ABI is a planned
      # follow-up (the cwire/runtime side is already in place).
      generateCBindings(
        ffiProcRegistry, ffiTypeRegistry, libName, outputDir, nimSrcRelPath
      )
    of "raw/rust":
      error(
        "genBindings: ffiMode=raw × ffiLang=rust is not yet implemented." &
          " Use -d:ffiMode=cbor for now, or wait for the Rust-over-pure-C cell."
      )
    else:
      error(
        "genBindings: unknown (ffiMode, ffiLang) = ('" & mode & "', '" & lang &
          "'). Valid ffiMode: raw|cbor. Valid ffiLang: cpp|rust."
      )

  # The cwire emission is **independent** of `ffiGenBindings`: even when no
  # header is produced, the runtime shim emitted by `.ffi.`/`.ffiCtor.`
  # references `cwirePack`/`cwireUnpack`/`cwireFree` per type. Those must
  # exist in the same compilation unit, so we splice them here.
  if isPureCMode():
    return buildCWireExtrasForRegistry()
  return newEmptyNode()
