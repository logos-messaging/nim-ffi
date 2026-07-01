import std/[macros, tables, strutils]
import chronos
import ../ffi_types
import ../codegen/[meta, string_helpers]
import ./c_macro_helpers
when defined(ffiGenBindings):
  import ../codegen/rust
  import ../codegen/cpp
  import ../codegen/cddl

proc requireLibraryDeclared(where: string) {.compileTime.} =
  ## Enforce that `declareLibrary(...)` (which records name/type/default-ABI)
  ## ran before this annotation.
  if not libraryDeclared:
    error(
      where &
        ": declareLibrary(name, LibType[, defaultABIFormat]) must be called before any FFI annotation"
    )

proc resolveABIFormat(abiSpecs: seq[NimNode]): ABIFormat {.compileTime.} =
  ## Resolve one annotation's ABI from its optional `"abi = ..."` string specs
  ## (last wins), inheriting the library default when absent.
  var fmt = currentDefaultABIFormat
  for spec in abiSpecs:
    if spec.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error(
        "FFI ABI override must be a string literal like \"abi = c\", got: " & spec.repr
      )
    let parsed = parseAbiSpec($spec)
    if not parsed.ok:
      error(parsed.err)
    fmt = parsed.fmt
  fmt

proc resolveFFISpecs(
    specs: seq[NimNode]
): tuple[abi: ABIFormat, timeoutMs: int] {.compileTime.} =
  ## Resolve an annotation's `"abi = ..."` and `"timeout = ..."` string specs
  ## (last of each wins), inheriting the library-default ABI when absent.
  ## `timeoutMs == 0` means "no per-proc override" (use the context default).
  var abi = currentDefaultABIFormat
  var timeoutMs = 0
  for spec in specs:
    if spec.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error(
        "FFI override must be a string literal like \"abi = c\" or " &
          "\"timeout = 30000\", got: " & spec.repr
      )
    case specKey($spec)
    of "abi":
      let parsed = parseAbiSpec($spec)
      if not parsed.ok:
        error(parsed.err)
      abi = parsed.fmt
    of "timeout":
      let parsed = parseTimeoutSpec($spec)
      if not parsed.ok:
        error(parsed.err)
      timeoutMs = parsed.ms
    else:
      error(
        "unknown FFI override '" & $spec & "'; expected `abi = ...` or `timeout = ...`"
      )
  (abi, timeoutMs)

proc registerRequestTimeout(
    reqTypeName: NimNode, timeoutMs: int
): NimNode {.compileTime.} =
  ## Top-level assignment that records a per-proc handler timeout at module init,
  ## keyed by the same Req type name the dispatcher registry uses. Empty when no
  ## override was given.
  if timeoutMs <= 0:
    return newStmtList()
  newAssignment(
    newTree(nnkBracketExpr, ident("requestTimeoutsMs"), newLit($reqTypeName)),
    newLit(timeoutMs),
  )

proc gateABIFormat(fmt: ABIFormat, where: string) {.compileTime.} =
  ## Abort if the selected ABI's codegen isn't wired yet (only `Cbor` is), so a
  ## `c` request fails loudly instead of emitting CBOR mislabeled as C.
  if not abiCodegenImplemented(fmt):
    error(
      where &
        ": ABI format is recognized but not yet implemented (only 'cbor' currently generates working bindings): " &
        $fmt
    )

proc gateFFITypeABIFormat(fmt: ABIFormat, where: string) {.compileTime.} =
  ## Type annotations only register metadata. `cbor` uses the generic CBOR
  ## overloads, while `c` emits its flat `_CWire` companion from `genBindings()`.
  case fmt
  of ABIFormat.Cbor, ABIFormat.C: discard

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

proc registerFFITypeInfo(
    typeDef: NimNode, abiFormat: ABIFormat
): NimNode {.compileTime.} =
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

  ffiTypeRegistry.add(
    FFITypeMeta(name: typeNameStr, fields: fieldMetas, abiFormat: abiFormat)
  )
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

proc isHandleType(typ: NimNode): bool =
  ## True iff `typ` is an `{.ffiHandle.}` type — its wire form is `uint64`.
  typ.kind == nnkIdent and isFFIHandleTypeName($typ)

proc storageType(typ: NimNode): NimNode =
  ## In-Req-struct storage type. `cstring` rides as `string`; an {.ffiHandle.}
  ## type rides as its `uint64` id; everything else as-is.
  if typ.kind == nnkIdent and $typ == "cstring":
    return ident("string")
  if isHandleType(typ):
    return ident("uint64")
  typ

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

proc unpackHandleField*(
    fieldIdent, userType, ctxIdent, decodedIdent: NimNode
): NimNode =
  ## Reconstitutes a handle param from its wire `uint64` via the ctx registry,
  ## returning `RET_ERR` (Result.err) on a stale/forged/wrong-type id.
  let errPrefix = "ffiHandle for parameter '" & $fieldIdent & "': "
  quote:
    let `fieldIdent` = block:
      let ffiH = `ctxIdent`[].handles.lookup(`decodedIdent`.`fieldIdent`, $`userType`).valueOr:
        return err(`errPrefix` & error)
      cast[`userType`](ffiH)

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

  # Handle params travel as their uint64 id; others keep the user's type.
  let procParams = procNode[3]
  for p in procParams[1 .. ^1]:
    if isHandleType(p[1]):
      formalParams.add(newIdentDefs(p[0], ident("uint64")))
      continue
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
    if isHandleType(p[1]):
      newBody.add unpackHandleField(p[0], p[1], reqHandler[0], decodedIdent)
      continue
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

  let handlerCtxIdent = genSym(nskLet, "handlerCtx")

  let callExpr = newCall(
    newDotExpr(reqTypeName, ident("processFFIRequest")),
    ident("request"),
    handlerCtxIdent,
  )

  let typedResIdent = genSym(nskLet, "typedRes")

  var newBody = newStmtList()
  newBody.add quote do:
    let `handlerCtxIdent` = cast[`rhsType`](reqHandler)
    let `typedResIdent` = await `callExpr`
    if `typedResIdent`.isErr:
      return err(`typedResIdent`.error)
    when typeof(`typedResIdent`.value) is seq[byte]:
      return ok(`typedResIdent`.value)
    elif typeof(`typedResIdent`.value) is void:
      return ok(newSeq[byte]())
    elif typeof(`typedResIdent`.value) is FFIHandleRoot:
      return ok(
        encodeHandle(
          `handlerCtxIdent`[].handles.register(
            `typedResIdent`.value, $typeof(`typedResIdent`.value)
          )
        )
      )
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

macro ffiRaw*(args: varargs[untyped]): untyped =
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
  ## The wire format follows the library default and can be overridden with
  ## `{.ffiRaw: "abi = c".}` / `{.ffiRaw: "abi = cbor".}`.
  ##
  ## e.g.:
  ##   proc waku_version(
  ##       ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
  ##   ) {.ffiRaw.} =
  ##     return ok(WakuNodeVersionString)

  requireLibraryDeclared("`.ffiRaw.`")
  let prc = args[^1]
  let (rawAbiFormat, rawTimeoutMs) = resolveFFISpecs(args[0 ..^ 2])
  gateABIFormat(rawAbiFormat, "`.ffiRaw.` proc")

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

  let stmts =
    newStmtList(registerReq, ffiProc, registerRequestTimeout(reqName, rawTimeoutMs))

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

macro ffiHandle*(args: varargs[untyped]): untyped =
  ## Marks a `ref object` as an opaque FFI handle. Its wire form is a `uint64`
  ## id; the live object stays in the per-ctx handle registry and never crosses.
  ##
  ##   type Kernel {.ffiHandle.} = ref object
  ##     ...
  ##
  ## An optional `"abi = ..."` spec is accepted for surface parity but only
  ## validated — a handle always rides as an abi-agnostic `uint64` id.
  requireLibraryDeclared("`.ffiHandle.`")
  let prc = args[^1]
  discard resolveABIFormat(args[0 ..^ 2])
  if prc.kind != nnkTypeDef:
    error("`.ffiHandle.` must be applied to a type definition")

  var clean = prc.copyNimTree()
  if clean[0].kind == nnkPragmaExpr:
    clean[0] = clean[0][0]

  let typeName =
    if clean[0].kind == nnkPostfix:
      clean[0][1]
    else:
      clean[0]

  let refTy = clean[2]
  if refTy.kind != nnkRefTy or refTy[0].kind != nnkObjectTy:
    error("`.ffiHandle.` type " & $typeName & " must be a `ref object`")
  let objTy = refTy[0]
  if objTy[1].kind != nnkEmpty:
    error("`.ffiHandle.` type " & $typeName & " must not already inherit a base")
  # Inherit the registry's storable base so handle refs share one static type.
  objTy[1] = nnkOfInherit.newTree(ident("FFIHandleRoot"))

  ffiHandleTypeNames.add($typeName)

  when defined(ffiDumpMacros):
    echo clean.repr
  return clean

macro ffi*(args: varargs[untyped]): untyped =
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
  ## The wire format defaults to the library's `defaultABIFormat` and can be
  ## overridden per annotation with `{.ffi: "abi = c".}` / `{.ffi: "abi = cbor".}`.
  ##
  ## Example (type):
  ##   type EchoRequest {.ffi.} = object
  ##     message: string
  ##     delayMs: int
  ##
  ## Example (proc):
  ##   proc mylib_send*(w: MyLib, cfg: SendConfig): Future[Result[string, string]] {.ffi.} =
  ##     return ok("done")

  # Annotated node is the last vararg; leading args are override specs.
  let prc = args[^1]
  let (abiFormat, timeoutMs) = resolveFFISpecs(args[0 ..^ 2])

  # A value type stands alone (no library required). Its `c` companion is
  # emitted later by `genBindings()`, since a type-pragma macro can only return
  # a TypeDef; `cbor` rides the generic overloads. Both abis are valid here.
  if prc.kind == nnkTypeDef:
    if timeoutMs > 0:
      error("`.ffi.` on a type takes no `timeout` override (it applies to procs)")
    gateFFITypeABIFormat(abiFormat, "`.ffi.` type")
    var cleanTypeDef = prc.copyNimTree()
    if cleanTypeDef[0].kind == nnkPragmaExpr:
      cleanTypeDef[0] = cleanTypeDef[0][0]
    return registerFFITypeInfo(cleanTypeDef, abiFormat)

  requireLibraryDeclared("`.ffi.`")
  gateABIFormat(abiFormat, "`.ffi.` proc")

  let procName = prc[0]
  let formalParams = prc[3]
  let bodyNode = prc[^1]

  if formalParams.len < 2:
    error("`.ffi.` procs require at least 1 parameter (the library type)")

  let firstParam = formalParams[1]
  let recvName = firstParam[0]
  let recvType = firstParam[1]
  let firstIsHandle = isHandleType(recvType)
  if firstIsHandle and currentLibType.len == 0:
    error(
      "`.ffi.` proc " & $procName & " has an {.ffiHandle.} receiver but no " &
        "library is declared; call declareLibrary(name, LibType) first"
    )
  # A handle receiver carries no library type, so fall back to the declared one.
  let libTypeName =
    if firstIsHandle:
      ident(currentLibType)
    else:
      recvType

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

  # A handle receiver rides the wire; a value-type lib receiver binds to ctx.myLib.
  var extraParamNames: seq[string] = @[]
  var extraParamTypes: seq[NimNode] = @[]
  let wireStart = if firstIsHandle: 1 else: 2
  for i in wireStart ..< formalParams.len:
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
    ## Reproduces the user's exact signature so it stays callable from Nim.
    var helperParams = newSeq[NimNode]()
    helperParams.add(retTypeNode)
    helperParams.add(newIdentDefs(recvName, recvType))
    for i in 2 ..< formalParams.len:
      let p = formalParams[i]
      for j in 0 ..< p.len - 2:
        helperParams.add(newIdentDefs(p[j], p[^2]))
    newProc(
      name = postfix(userProcName, "*"),
      params = helperParams,
      body = newStmtList(bodyNode),
      pragmas = newTree(nnkPragma, ident("async")),
    )

  proc asyncPath(): NimNode =
    ## Emits the C-exported wrapper and registers the handler. Every `.ffi.` proc
    ## dispatches through the FFI thread and replies via its callback, honouring
    ## `foreignThreadGc`, the MPSC ingress hand-off, and chronos's invariant.
    let helperProc = buildAsyncHelperProc()

    # registerReqFFI lambda: typed params, returns user's typed Result.
    let ctxHandlerName = ident("ffiCtxHandler")
    let ptrFFICtx =
      nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libTypeName))

    var lambdaParams = newSeq[NimNode]()
    lambdaParams.add(retTypeNode) # Future[Result[RetType, string]]
    for i in 0 ..< extraParamNames.len:
      lambdaParams.add(newIdentDefs(ident(extraParamNames[i]), extraParamTypes[i]))

    let helperCall = newTree(nnkCall, userProcName)
    if not firstIsHandle:
      let ctxMyLib = newDotExpr(newTree(nnkDerefExpr, ctxHandlerName), ident("myLib"))
      helperCall.add(newTree(nnkDerefExpr, ctxMyLib))
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
        let isPointer = isPtr(ptype)
        let handle = isHandleType(ptype)
        let tn =
          if isPointer:
            nimTypeNameRepr(ptype[0])
          else:
            nimTypeNameRepr(ptype)
        ffiExtraParams.add(
          FFIParamMeta(
            name: extraParamNames[i], typeName: tn, isPtr: isPointer, isHandle: handle
          )
        )
      let retTypeInner = resultInner[1]
      let retIsPtr = isPtr(retTypeInner)
      let retIsHandle = isHandleType(retTypeInner)
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
          returnIsHandle: retIsHandle,
          abiFormat: abiFormat,
        )
      )

    return newStmtList(
      helperProc, registerReq, ffiProc, registerRequestTimeout(reqTypeName, timeoutMs)
    )

  let stmts = asyncPath()

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

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

macro ffiCtor*(args: varargs[untyped]): untyped =
  ## Defines a C-exported constructor that creates an FFIContext and populates
  ## ctx.myLib asynchronously in the FFI thread.
  ##
  ## The annotated proc must:
  ##   - Have Nim-typed parameters (carried over the wire as a single CBOR blob)
  ##   - Return Future[Result[LibType, string]]
  ##   - NOT include ctx, callback, or userData in its signature
  ##
  ## The wire format follows the library default and can be overridden with
  ## `{.ffiCtor: "abi = c".}` / `{.ffiCtor: "abi = cbor".}`.
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

  requireLibraryDeclared("`.ffiCtor.`")
  let prc = args[^1]
  let (abiFormat, timeoutMs) = resolveFFISpecs(args[0 ..^ 2])
  gateABIFormat(abiFormat, "`.ffiCtor.` proc")

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
        abiFormat: abiFormat,
      )
    )

  let poolDecl = quote:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts = newStmtList(
    typeDef,
    ffiNewReqProc,
    helperProc,
    processProc,
    addToReg,
    poolDecl,
    ffiProc,
    registerRequestTimeout(reqTypeName, timeoutMs),
  )

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

macro ffiDtor*(args: varargs[untyped]): untyped =
  ## Defines a C-exported destructor that tears down the FFIContext after the
  ## body runs.
  ##
  ## The annotated proc must have exactly one parameter of the library type.
  ## The body contains any library-level cleanup to run before context teardown.
  ##
  ## The wire format follows the library default and can be overridden with
  ## `{.ffiDtor: "abi = c".}` / `{.ffiDtor: "abi = cbor".}`.
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

  requireLibraryDeclared("`.ffiDtor.`")
  let prc = args[^1]
  let abiFormat = resolveABIFormat(args[0 ..^ 2])
  gateABIFormat(abiFormat, "`.ffiDtor.` proc")

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
      abiFormat: abiFormat,
    )
  )

  let poolDecl = quote:
    when not declared(`poolIdent`):
      var `poolIdent`: FFIContextPool[`libTypeName`]

  let stmts = newStmtList(poolDecl, ffiProc)

  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts

macro ffiEvent*(args: varargs[untyped]): untyped =
  ## Declares a library-initiated event. The annotated proc has an empty
  ## body — the macro fills it with a `dispatchFFIEventCbor` call so the
  ## Nim author dispatches the event by calling the proc with a typed
  ## payload, and the per-target codegens emit a typed handler dispatcher
  ## on the foreign side.
  ##
  ## The first pragma argument is the wire-format event name, taken verbatim
  ## (no case conversion). That string appears in the CBOR `eventType` field
  ## and is the single source of truth across Nim / C++ / Rust bindings.
  ##
  ## The wire format follows the library default and can be overridden by
  ## passing an `"abi = ..."` spec after the event name, e.g.
  ## `{.ffiEvent("on_peer_connected", "abi = cbor").}`.
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

  requireLibraryDeclared("`.ffiEvent.`")
  if args.len < 2:
    error("ffiEvent requires a wire-name string and a proc declaration")

  let prc = args[^1]
  if prc.kind notin {nnkProcDef, nnkFuncDef}:
    error("ffiEvent must be applied to a proc declaration")

  if args[0].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("ffiEvent: the first argument must be the wire-name string literal")
  let wireName = $args[0]
  # Args between the wire name and the proc are ABI override specs.
  let abiFormat = resolveABIFormat(args[1 ..^ 2])
  gateABIFormat(abiFormat, "`.ffiEvent.` proc")

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
      abiFormat: abiFormat,
    )
  )

  when defined(ffiDumpMacros):
    echo generated.repr
  return generated

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
  ## Foreign-binding file emission is a no-op unless -d:ffiGenBindings is set;
  ## the `abi = c` `_CWire` companions are emitted unconditionally (runtime
  ## code, not generated files).
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
    else:
      error(
        "genBindings: unknown targetLang '" & lang & "'. Use 'rust', 'cpp', or 'cddl'."
      )

  let cwireCompanions = flushCWireCompanions()
  when defined(ffiDumpMacros):
    echo cwireCompanions.repr
  cwireCompanions
