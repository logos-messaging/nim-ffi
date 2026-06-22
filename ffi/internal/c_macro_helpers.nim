## Compile-time helpers for the `c` (flat C-struct) ABI of `{.ffi: "abi = c".}`
## types. Each gets a `T_CWire` companion (string→cstring, seq→items+len pair,
## Option→ptr, nested ffi type→its `_CWire`, POD as-is) plus runtime
## `cwirePack` / `cwireUnpack` / `cwireFree`. Wire structs live in `allocShared`
## memory so they cross the FFI thread channel without touching either GC heap.

import std/macros
import ../codegen/meta

proc isKnownFFIType(name: string): bool {.compileTime.} =
  for t in ffiTypeRegistry:
    if t.name == name:
      return true
  false

var emittedCWireTypes* {.compileTime.}: seq[string]

proc isCWireEmitted*(typeName: string): bool {.compileTime.} =
  ## Indexed loop, not `for x in seq`: a Nim 2.2 compile-time VM quirk returns
  ## stale reads of a freshly-mutated `{.compileTime.}` seq within one expansion.
  var found = false
  for i in 0 ..< emittedCWireTypes.len:
    if emittedCWireTypes[i] == typeName:
      found = true
      break
  found

proc markCWireEmitted*(typeName: string) {.compileTime.} =
  if not isCWireEmitted(typeName):
    emittedCWireTypes.add(typeName)

proc cwireTypeName*(userTypeName: string): string =
  userTypeName & "_CWire"

proc isStringType(t: NimNode): bool =
  t.kind == nnkIdent and ($t == "string" or $t == "cstring")

proc isSeqType(t: NimNode): bool =
  t.kind == nnkBracketExpr and t.len >= 2 and t[0].kind == nnkIdent and $t[0] == "seq"

proc isOptionType(t: NimNode): bool =
  t.kind == nnkBracketExpr and t.len >= 2 and t[0].kind == nnkIdent and
    ($t[0] == "Option" or $t[0] == "Maybe")

proc isNestedFFIType(t: NimNode): bool =
  t.kind == nnkIdent and isKnownFFIType($t)

proc wireFieldType(userType: NimNode): NimNode =
  ## User field type AST → wire-form AST. `seq` is handled by `wireFieldsFor`,
  ## which must split it into two physical fields.
  if isStringType(userType):
    return ident("cstring")
  if isOptionType(userType):
    let inner = userType[1]
    let innerWire =
      if isNestedFFIType(inner):
        ident(cwireTypeName($inner))
      else:
        wireFieldType(inner)
    return nnkPtrTy.newTree(innerWire)
  if isNestedFFIType(userType):
    return ident(cwireTypeName($userType))
  userType

proc wireFieldsFor*(fieldName: string, fieldType: NimNode): seq[NimNode] =
  ## The IdentDefs (one, or two for `seq`) for `fieldName` in the wire object.
  if isSeqType(fieldType):
    let elem = fieldType[1]
    let elemWire =
      if isNestedFFIType(elem):
        ident(cwireTypeName($elem))
      else:
        wireFieldType(elem)
    let itemsField = newIdentDefs(
      ident(fieldName & "_items"),
      nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("UncheckedArray"), elemWire)),
      newEmptyNode(),
    )
    let lenField = newIdentDefs(ident(fieldName & "_len"), ident("int"), newEmptyNode())
    return @[itemsField, lenField]
  @[newIdentDefs(ident(fieldName), wireFieldType(fieldType), newEmptyNode())]

proc buildCWireTypeDef*(
    userTypeName: string, fieldNames: seq[string], fieldTypes: seq[NimNode]
): NimNode =
  ## Bare `nnkTypeDef` for the wire companion; the caller splices it into a
  ## TypeSection.
  let wireName = ident(cwireTypeName(userTypeName))
  var fields: seq[NimNode] = @[]
  for i in 0 ..< fieldNames.len:
    for fd in wireFieldsFor(fieldNames[i], fieldTypes[i]):
      fields.add(fd)
  let recList =
    if fields.len > 0:
      newTree(nnkRecList, fields)
    else:
      newTree(
        nnkRecList, newIdentDefs(ident("_placeholder"), ident("uint8"), newEmptyNode())
      )
  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)
  newTree(nnkTypeDef, postfix(wireName, "*"), newEmptyNode(), objTy)

proc emitElemPack(dstElem, srcElem, elemType: NimNode): NimNode =
  ## Single-element pack for the seq/Option emitters.
  if isStringType(elemType):
    return newAssignment(dstElem, newCall(ident("cwireAllocStr"), srcElem))
  if isNestedFFIType(elemType):
    return newCall(ident("cwirePack"), dstElem, srcElem)
  newAssignment(dstElem, srcElem)

proc emitElemUnpack(dstElem, srcElem, elemType: NimNode): NimNode =
  if isStringType(elemType):
    return newAssignment(dstElem, newCall(ident("$"), srcElem))
  if isNestedFFIType(elemType):
    return newAssignment(dstElem, newCall(ident("cwireUnpack"), srcElem))
  newAssignment(dstElem, srcElem)

proc emitElemFree(elemAccess, elemType: NimNode): NimNode =
  if isStringType(elemType):
    return newCall(ident("cwireFreeStr"), elemAccess)
  if isNestedFFIType(elemType):
    return newCall(ident("cwireFree"), elemAccess)
  newEmptyNode()

proc emitPackStmt(dstObj, srcObj, fieldNameIdent, userType: NimNode): seq[NimNode] =
  ## Stmts populating `dstObj.<field>` from `srcObj.<field>`, allocating shared
  ## cstrings/arrays as needed. Multi-statement for seq/Option.
  var stmts: seq[NimNode] = @[]
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(dstObj, fieldNameIdent)

  if isStringType(userType):
    stmts.add(newAssignment(dstAccess, newCall(ident("cwireAllocStr"), srcAccess)))
    return stmts

  if isNestedFFIType(userType):
    stmts.add(newCall(ident("cwirePack"), dstAccess, srcAccess))
    return stmts

  if isSeqType(userType):
    let elemType = userType[1]
    let wireElemType =
      if isNestedFFIType(elemType):
        ident(cwireTypeName($elemType))
      else:
        wireFieldType(elemType)
    let itemsField = newDotExpr(dstObj, ident($fieldNameIdent & "_items"))
    let lenField = newDotExpr(dstObj, ident($fieldNameIdent & "_len"))
    let bufType =
      nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("UncheckedArray"), wireElemType))
    let idx = genSym(nskForVar, "i")
    let elemPack = emitElemPack(
      nnkBracketExpr.newTree(itemsField, idx),
      nnkBracketExpr.newTree(srcAccess, idx),
      elemType,
    )
    let body = newStmtList(elemPack)
    let forLoop = nnkForStmt.newTree(
      idx,
      nnkInfix.newTree(ident("..<"), newLit(0), newDotExpr(srcAccess, ident("len"))),
      body,
    )
    stmts.add quote do:
      if `srcAccess`.len == 0:
        `itemsField` = nil
        `lenField` = 0
      else:
        `itemsField` =
          cast[`bufType`](allocShared(sizeof(`wireElemType`) * `srcAccess`.len))
        `forLoop`
        `lenField` = `srcAccess`.len
    return stmts

  if isOptionType(userType):
    let innerType = userType[1]
    let wireInnerType =
      if isNestedFFIType(innerType):
        ident(cwireTypeName($innerType))
      else:
        wireFieldType(innerType)
    let bufType = nnkPtrTy.newTree(wireInnerType)
    let elemPack = emitElemPack(
      nnkBracketExpr.newTree(dstAccess), newCall(ident("get"), srcAccess), innerType
    )
    stmts.add quote do:
      if `srcAccess`.isSome:
        `dstAccess` = cast[`bufType`](allocShared(sizeof(`wireInnerType`)))
        `elemPack`
      else:
        `dstAccess` = nil
    return stmts

  stmts.add(newAssignment(dstAccess, srcAccess))
  stmts

proc emitUnpackStmt(
    resultObj, srcObj, fieldNameIdent, userType: NimNode
): seq[NimNode] =
  var stmts: seq[NimNode] = @[]
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(resultObj, fieldNameIdent)

  if isStringType(userType):
    let dollar = newCall(ident("$"), srcAccess) # copies into Nim-managed memory
    stmts.add(newAssignment(dstAccess, dollar))
    return stmts

  if isNestedFFIType(userType):
    stmts.add(newAssignment(dstAccess, newCall(ident("cwireUnpack"), srcAccess)))
    return stmts

  if isSeqType(userType):
    let elemType = userType[1]
    let itemsField = newDotExpr(srcObj, ident($fieldNameIdent & "_items"))
    let lenField = newDotExpr(srcObj, ident($fieldNameIdent & "_len"))
    let elemVar = genSym(nskVar, "elem")
    let idx = genSym(nskForVar, "i")
    let elemUnpack =
      emitElemUnpack(elemVar, nnkBracketExpr.newTree(itemsField, idx), elemType)
    stmts.add quote do:
      `dstAccess` = @[]
      for `idx` in 0 ..< `lenField`:
        var `elemVar`: `elemType`
        `elemUnpack`
        `dstAccess`.add(`elemVar`)
    return stmts

  if isOptionType(userType):
    let innerType = userType[1]
    let elemVar = genSym(nskVar, "innerVal")
    let elemUnpack =
      emitElemUnpack(elemVar, nnkBracketExpr.newTree(srcAccess), innerType)
    stmts.add quote do:
      if `srcAccess`.isNil:
        `dstAccess` = none(`innerType`)
      else:
        var `elemVar`: `innerType`
        `elemUnpack`
        `dstAccess` = some(`elemVar`)
    return stmts

  stmts.add(newAssignment(dstAccess, srcAccess))
  stmts

proc emitFreeStmt(dstObj, fieldNameIdent, userType: NimNode): seq[NimNode] =
  var stmts: seq[NimNode] = @[]
  let dstAccess = newDotExpr(dstObj, fieldNameIdent)

  if isStringType(userType):
    stmts.add(newCall(ident("cwireFreeStr"), dstAccess))
    return stmts

  if isNestedFFIType(userType):
    stmts.add(newCall(ident("cwireFree"), dstAccess))
    return stmts

  if isSeqType(userType):
    let elemType = userType[1]
    let itemsField = newDotExpr(dstObj, ident($fieldNameIdent & "_items"))
    let lenField = newDotExpr(dstObj, ident($fieldNameIdent & "_len"))
    let idx = genSym(nskForVar, "i")
    let elemFree = emitElemFree(nnkBracketExpr.newTree(itemsField, idx), elemType)
    let body =
      if elemFree.kind == nnkEmpty:
        newStmtList(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
      else:
        newStmtList(elemFree)
    stmts.add quote do:
      if not `itemsField`.isNil:
        for `idx` in 0 ..< `lenField`:
          `body`
        deallocShared(`itemsField`)
        `itemsField` = nil
        `lenField` = 0
    return stmts

  if isOptionType(userType):
    let innerType = userType[1]
    let elemFree = emitElemFree(nnkBracketExpr.newTree(dstAccess), innerType)
    let body =
      if elemFree.kind == nnkEmpty:
        newStmtList(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
      else:
        newStmtList(elemFree)
    stmts.add quote do:
      if not `dstAccess`.isNil:
        `body`
        deallocShared(`dstAccess`)
        `dstAccess` = nil
    return stmts

  stmts

proc buildCWireProcs*(
    userTypeName: string, fieldNames: seq[string], fieldTypes: seq[NimNode]
): seq[NimNode] =
  ## Generate public `cwirePack` / `cwireUnpack` / `cwireFree` (+ a pointer
  ## thunk) for `userTypeName`, callable across module boundaries.
  let userName = ident(userTypeName)
  let wireName = ident(cwireTypeName(userTypeName))

  let packDst = ident("dst")
  let packSrc = ident("src")
  var packBody = newStmtList()
  for i in 0 ..< fieldNames.len:
    let fIdent = ident(fieldNames[i])
    for s in emitPackStmt(packDst, packSrc, fIdent, fieldTypes[i]):
      packBody.add(s)
  if fieldNames.len == 0:
    packBody.add quote do:
      discard
  let packProc = newProc(
    name = postfix(ident("cwirePack"), "*"),
    params = @[
      newEmptyNode(),
      newIdentDefs(packDst, nnkVarTy.newTree(wireName)),
      newIdentDefs(packSrc, userName),
    ],
    body = packBody,
  )

  let unpSrc = ident("src")
  let unpRes = ident("res")
  var unpBody = newStmtList()
  unpBody.add quote do:
    var `unpRes`: `userName`
  for i in 0 ..< fieldNames.len:
    let fIdent = ident(fieldNames[i])
    for s in emitUnpackStmt(unpRes, unpSrc, fIdent, fieldTypes[i]):
      unpBody.add(s)
  unpBody.add quote do:
    return `unpRes`
  let unpProc = newProc(
    name = postfix(ident("cwireUnpack"), "*"),
    params = @[userName, newIdentDefs(unpSrc, wireName)],
    body = unpBody,
  )

  let freeDst = ident("dst")
  var freeBody = newStmtList()
  for i in 0 ..< fieldNames.len:
    let fIdent = ident(fieldNames[i])
    for s in emitFreeStmt(freeDst, fIdent, fieldTypes[i]):
      freeBody.add(s)
  if freeBody.len == 0:
    freeBody.add quote do:
      discard
  let freeProc = newProc(
    name = postfix(ident("cwireFree"), "*"),
    params = @[newEmptyNode(), newIdentDefs(freeDst, nnkVarTy.newTree(wireName))],
    body = freeBody,
  )

  # Pointer-typed thunk for the shim's CleanupProc slot — named, since `nimcall`
  # forbids closures.
  let thunkName = ident("cwireFreePtr_" & userTypeName)
  let thunkP = ident("p")
  let thunkBody = newStmtList()
  thunkBody.add quote do:
    if `thunkP`.isNil:
      return
    cwireFree(cast[ptr `wireName`](`thunkP`)[])
  let thunkProc = newProc(
    name = postfix(thunkName, "*"),
    params = @[newEmptyNode(), newIdentDefs(thunkP, ident("pointer"))],
    body = thunkBody,
    pragmas = newTree(
      nnkPragma,
      ident("nimcall"),
      ident("gcsafe"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  @[packProc, unpProc, freeProc, thunkProc]

proc collectNestedFFITypes*(
    fieldTypes: seq[NimNode], deps: var seq[string]
) {.compileTime.} =
  ## Append (deduped) the names of nested ffi types in `fieldTypes`, including
  ## one level of `seq[X]` / `Option[X]` / `Maybe[X]`.
  for t in fieldTypes:
    if isNestedFFIType(t):
      let n = $t
      if n notin deps:
        deps.add(n)
    elif isSeqType(t) or isOptionType(t):
      let inner = t[1]
      if isNestedFFIType(inner):
        let n = $inner
        if n notin deps:
          deps.add(n)

proc fieldInfoForType(
    typeName: string
): tuple[names: seq[string], types: seq[NimNode]] {.compileTime.} =
  ## Field names + parsed type ASTs for an ffi type, from the registry.
  var info: tuple[names: seq[string], types: seq[NimNode]]
  for tm in ffiTypeRegistry:
    if tm.name == typeName:
      for f in tm.fields:
        info.names.add(f.name)
        info.types.add(parseExpr(f.typeName))
      return info
  error("ensureCWireFor: ffi type '" & typeName & "' not in registry")

proc ensureCWireFor*(typeName: string, sink: NimNode) {.compileTime.} =
  ## Idempotently append `typeName`'s wire TypeSection + conversion procs to
  ## `sink`, recursing into nested ffi types first. Called by `genBindings()`.
  if isCWireEmitted(typeName):
    return

  let info = fieldInfoForType(typeName)

  var deps: seq[string] = @[]
  collectNestedFFITypes(info.types, deps)
  for dep in deps:
    ensureCWireFor(dep, sink)

  markCWireEmitted(typeName)

  let wireTypeDef = buildCWireTypeDef(typeName, info.names, info.types)
  let section = newNimNode(nnkTypeSection)
  section.add(wireTypeDef)
  sink.add(section)
  for p in buildCWireProcs(typeName, info.names, info.types):
    sink.add(p)
