## Compile-time helpers for the `abi = c` C-struct ABI: for each `{.ffi: "abi = c".}`
## object T, emits a `T_CWire` companion plus `cwirePack`/`cwireUnpack`/`cwireFree`.
## A `seq` may only be a top-level field (no single-field wire form to nest).

import std/macros
import ../codegen/meta

const
  cwireItemsSuffix = "_items"
  cwireLenSuffix = "_len"

var emittedCWireTypes {.compileTime.}: seq[string]

proc isCWireEmitted(typeName: string): bool {.compileTime.} =
  # Indexed scan: `for x in seq` over a freshly-mutated compileTime seq goes stale on the Nim 2.2 VM.
  for i in 0 ..< emittedCWireTypes.len:
    if emittedCWireTypes[i] == typeName:
      return true
  false

proc markCWireEmitted(typeName: string) {.compileTime.} =
  if not isCWireEmitted(typeName):
    emittedCWireTypes.add(typeName)

proc cwireTypeName(userTypeName: string): string =
  userTypeName & "_CWire"

proc seqItemsField(obj, field: NimNode): NimNode =
  newDotExpr(obj, ident($field & cwireItemsSuffix))

proc seqLenField(obj, field: NimNode): NimNode =
  newDotExpr(obj, ident($field & cwireLenSuffix))

proc isStringType(t: NimNode): bool =
  t.kind == nnkIdent and ($t == "string" or $t == "cstring")

proc isBracketOf(t: NimNode, heads: openArray[string]): bool =
  t.kind == nnkBracketExpr and t.len >= 2 and t[0].kind == nnkIdent and $t[0] in heads

proc isSeqType(t: NimNode): bool =
  isBracketOf(t, ["seq"])

proc isOptionType(t: NimNode): bool =
  isBracketOf(t, ["Option", "Maybe"])

proc isArrayType(t: NimNode): bool =
  t.kind == nnkBracketExpr and t.len == 3 and t[0].kind == nnkIdent and $t[0] == "array"

proc isTupleType(t: NimNode): bool =
  t.kind == nnkTupleTy

proc tupleComponents(t: NimNode): seq[tuple[name: string, typ: NimNode]] =
  ## Flatten a named tuple into `(name, type)` pairs, one per name.
  var comps: seq[tuple[name: string, typ: NimNode]] = @[]
  for defs in t:
    if defs.kind != nnkIdentDefs:
      error("cwire: only named tuples are supported: " & t.repr)
    let typ = defs[^2]
    for i in 0 ..< defs.len - 2:
      comps.add((name: $defs[i], typ: typ))
  comps

proc isKnownFFIType(name: string): bool {.compileTime.} =
  for typeMeta in ffiTypeRegistry:
    if typeMeta.name == name and not typeMeta.isEnum():
      return true
  false

proc isNestedFFIType(t: NimNode): bool =
  ## Enums are excluded: they are registered types but have no `_CWire`
  ## companion, and treating one as a nested struct would silently drop its value.
  t.kind == nnkIdent and isKnownFFIType($t)

proc rejectEnumOnCWire(t: NimNode) {.compileTime.} =
  if t.kind == nnkIdent and isFFIEnumTypeName($t):
    error(
      "cwire: `abi = c` does not support enum types yet, but " & $t &
        " crosses the boundary here; use the CBOR ABI for this proc or type"
    )

proc cwireNeedsFree(t: NimNode): bool =
  ## Whether the wire form of `t` owns allocations `cwireFree` must release.
  if isStringType(t) or isNestedFFIType(t) or isOptionType(t) or isSeqType(t):
    return true
  if isArrayType(t):
    return cwireNeedsFree(t[2])
  if isTupleType(t):
    for c in tupleComponents(t):
      if cwireNeedsFree(c.typ):
        return true
    return false
  false

proc rejectNestedSeq(t: NimNode) =
  error(
    "cwire: `seq` has no single-field wire form, so it can't nest inside " &
      "another container (use it only as a top-level field): " & t.repr
  )

proc wireValueType(t: NimNode): NimNode =
  ## Single-field wire form of value type `t`; `seq` has none, so it errors here.
  rejectEnumOnCWire(t)
  if isStringType(t):
    return ident("cstring")
  if isNestedFFIType(t):
    return ident(cwireTypeName($t))
  if isOptionType(t):
    return nnkPtrTy.newTree(wireValueType(t[1]))
  if isArrayType(t):
    return
      nnkBracketExpr.newTree(ident("array"), t[1].copyNimTree(), wireValueType(t[2]))
  if isTupleType(t):
    let wireTup = nnkTupleTy.newTree()
    for c in tupleComponents(t):
      wireTup.add(newIdentDefs(ident(c.name), wireValueType(c.typ)))
    return wireTup
  if isSeqType(t):
    rejectNestedSeq(t)
  t

proc wireFieldsFor(fieldName: string, fieldType: NimNode): seq[NimNode] =
  ## IdentDefs for one field; `seq[T]` splits into `_items` + `_len`.
  if isSeqType(fieldType):
    let elemWire = wireValueType(fieldType[1])
    let itemsField = newIdentDefs(
      ident(fieldName & cwireItemsSuffix),
      nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("UncheckedArray"), elemWire)),
      newEmptyNode(),
    )
    let lenField =
      newIdentDefs(ident(fieldName & cwireLenSuffix), ident("int"), newEmptyNode())
    return @[itemsField, lenField]
  @[newIdentDefs(ident(fieldName), wireValueType(fieldType), newEmptyNode())]

proc buildCWireTypeDef(
    userTypeName: string, fieldNames: seq[string], fieldTypes: seq[NimNode]
): NimNode =
  ## Build the bare `nnkTypeDef` for the wire companion of `userTypeName`.
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

proc emitOptionPack(dstAccess, srcAccess, userType: NimNode): NimNode
proc emitOptionUnpack(dstAccess, srcAccess, userType: NimNode): NimNode
proc emitOptionFree(dstAccess, userType: NimNode): NimNode
proc emitArrayPack(dstAccess, srcAccess, arrType: NimNode): NimNode
proc emitArrayUnpack(dstAccess, srcAccess, arrType: NimNode): NimNode
proc emitArrayFree(dstAccess, arrType: NimNode): NimNode
proc emitTuplePack(dstAccess, srcAccess, tupType: NimNode): NimNode
proc emitTupleUnpack(dstAccess, srcAccess, tupType: NimNode): NimNode
proc emitTupleFree(dstAccess, tupType: NimNode): NimNode

proc emitElemPack(dstElem, srcElem, elemType: NimNode): NimNode =
  ## Pack one value; recurses through nested ffi/Option/array/tuple, POD copied.
  if isStringType(elemType):
    return newAssignment(dstElem, newCall(ident("cwireAllocStr"), srcElem))
  if isNestedFFIType(elemType):
    return newCall(ident("cwirePack"), dstElem, srcElem)
  if isOptionType(elemType):
    return emitOptionPack(dstElem, srcElem, elemType)
  if isArrayType(elemType):
    return emitArrayPack(dstElem, srcElem, elemType)
  if isTupleType(elemType):
    return emitTuplePack(dstElem, srcElem, elemType)
  if isSeqType(elemType):
    rejectNestedSeq(elemType)
  newAssignment(dstElem, srcElem)

proc emitElemUnpack(dstElem, srcElem, elemType: NimNode): NimNode =
  ## Inverse of `emitElemPack`: copy one value back into Nim memory.
  if isStringType(elemType):
    return newAssignment(dstElem, newCall(ident("$"), srcElem))
  if isNestedFFIType(elemType):
    return newAssignment(dstElem, newCall(ident("cwireUnpack"), srcElem))
  if isOptionType(elemType):
    return emitOptionUnpack(dstElem, srcElem, elemType)
  if isArrayType(elemType):
    return emitArrayUnpack(dstElem, srcElem, elemType)
  if isTupleType(elemType):
    return emitTupleUnpack(dstElem, srcElem, elemType)
  if isSeqType(elemType):
    rejectNestedSeq(elemType)
  newAssignment(dstElem, srcElem)

proc emitElemFree(elemAccess, elemType: NimNode): NimNode =
  ## Free one value, or `nnkEmpty` for POD.
  if isStringType(elemType):
    return newCall(ident("cwireFreeStr"), elemAccess)
  if isNestedFFIType(elemType):
    return newCall(ident("cwireFree"), elemAccess)
  if isOptionType(elemType):
    return emitOptionFree(elemAccess, elemType)
  if isArrayType(elemType):
    return emitArrayFree(elemAccess, elemType)
  if isTupleType(elemType):
    return emitTupleFree(elemAccess, elemType)
  if isSeqType(elemType):
    rejectNestedSeq(elemType)
  newEmptyNode()

proc maybeStmt(n: NimNode): NimNode =
  ## `n` as a one-statement list, empty list when `nnkEmpty`.
  if n.kind == nnkEmpty:
    return newStmtList()
  newStmtList(n)

proc indexLoop(access, idx, body: NimNode): NimNode =
  ## `for <idx> in low(access) .. high(access): body` (covers non-0-based ranges).
  nnkForStmt.newTree(
    idx,
    nnkInfix.newTree(
      ident(".."), newCall(ident("low"), access), newCall(ident("high"), access)
    ),
    newStmtList(body),
  )

proc emitArrayPack(dstAccess, srcAccess, arrType: NimNode): NimNode =
  ## Pack a fixed `array[N, T]` element-by-element into the inline wire array.
  let idx = genSym(nskForVar, "i")
  let body = emitElemPack(
    nnkBracketExpr.newTree(dstAccess, idx),
    nnkBracketExpr.newTree(srcAccess, idx),
    arrType[2],
  )
  indexLoop(srcAccess, idx, body)

proc emitArrayUnpack(dstAccess, srcAccess, arrType: NimNode): NimNode =
  ## Inverse of `emitArrayPack`.
  let idx = genSym(nskForVar, "i")
  let body = emitElemUnpack(
    nnkBracketExpr.newTree(dstAccess, idx),
    nnkBracketExpr.newTree(srcAccess, idx),
    arrType[2],
  )
  indexLoop(srcAccess, idx, body)

proc emitArrayFree(dstAccess, arrType: NimNode): NimNode =
  ## Free each array element; `nnkEmpty` when the element owns nothing.
  if not cwireNeedsFree(arrType[2]):
    return newEmptyNode()
  let idx = genSym(nskForVar, "i")
  let body = emitElemFree(nnkBracketExpr.newTree(dstAccess, idx), arrType[2])
  indexLoop(dstAccess, idx, body)

proc emitTuplePack(dstAccess, srcAccess, tupType: NimNode): NimNode =
  ## Pack each named tuple component into the matching wire component.
  let body = newStmtList()
  for c in tupleComponents(tupType):
    let nm = ident(c.name)
    body.add(emitElemPack(newDotExpr(dstAccess, nm), newDotExpr(srcAccess, nm), c.typ))
  body

proc emitTupleUnpack(dstAccess, srcAccess, tupType: NimNode): NimNode =
  ## Inverse of `emitTuplePack`.
  let body = newStmtList()
  for c in tupleComponents(tupType):
    let nm = ident(c.name)
    body.add(
      emitElemUnpack(newDotExpr(dstAccess, nm), newDotExpr(srcAccess, nm), c.typ)
    )
  body

proc emitTupleFree(dstAccess, tupType: NimNode): NimNode =
  ## Free each tuple component that owns allocations.
  if not cwireNeedsFree(tupType):
    return newEmptyNode()
  let body = newStmtList()
  for c in tupleComponents(tupType):
    body.add(maybeStmt(emitElemFree(newDotExpr(dstAccess, ident(c.name)), c.typ)))
  body

proc emitSeqPack(dstObj, srcAccess, fieldNameIdent, userType: NimNode): NimNode =
  ## Pack a seq into an `allocShared` `UncheckedArray`; empty = nil items + 0 len.
  let elemType = userType[1]
  let wireElem = wireValueType(elemType)
  let items = seqItemsField(dstObj, fieldNameIdent)
  let count = seqLenField(dstObj, fieldNameIdent)
  let bufType =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("UncheckedArray"), wireElem))
  let idx = genSym(nskForVar, "i")
  let elemPack = emitElemPack(
    nnkBracketExpr.newTree(items, idx), nnkBracketExpr.newTree(srcAccess, idx), elemType
  )
  let forLoop = nnkForStmt.newTree(
    idx,
    nnkInfix.newTree(
      ident("..<"), newLit(0), newCall(newDotExpr(srcAccess, ident("len")))
    ),
    newStmtList(elemPack),
  )
  quote:
    if `srcAccess`.len() == 0:
      `items` = nil
      `count` = 0
    else:
      `items` = cast[`bufType`](allocShared(sizeof(`wireElem`) * `srcAccess`.len()))
      `forLoop`
      `count` = `srcAccess`.len()

proc emitOptionPack(dstAccess, srcAccess, userType: NimNode): NimNode =
  ## Pack an Option into a `ptr`: some → `allocShared` box, none → nil. Payload
  ## read into a local once so a composite inner type isn't re-`get()` per element.
  let innerType = userType[1]
  let wireInner = wireValueType(innerType)
  let bufType = nnkPtrTy.newTree(wireInner)
  let innerVal = genSym(nskLet, "innerVal")
  let elemPack = emitElemPack(nnkBracketExpr.newTree(dstAccess), innerVal, innerType)
  quote:
    if `srcAccess`.isSome():
      `dstAccess` = cast[`bufType`](allocShared(sizeof(`wireInner`)))
      let `innerVal` = `srcAccess`.get()
      `elemPack`
    else:
      `dstAccess` = nil

proc emitPackStmt(dstObj, srcObj, fieldNameIdent, userType: NimNode): seq[NimNode] =
  ## Populate `dstObj.<field>` from `srcObj.<field>`.
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(dstObj, fieldNameIdent)
  if isSeqType(userType):
    return @[emitSeqPack(dstObj, srcAccess, fieldNameIdent, userType)]
  @[emitElemPack(dstAccess, srcAccess, userType)]

proc emitSeqUnpack(dstAccess, srcObj, fieldNameIdent, userType: NimNode): NimNode =
  ## Rebuild a Nim seq from the `_items`/`_len` wire pair.
  let elemType = userType[1]
  let items = seqItemsField(srcObj, fieldNameIdent)
  let count = seqLenField(srcObj, fieldNameIdent)
  let elemVar = genSym(nskVar, "elem")
  let idx = genSym(nskForVar, "i")
  let elemUnpack = emitElemUnpack(elemVar, nnkBracketExpr.newTree(items, idx), elemType)
  quote:
    `dstAccess` = @[]
    for `idx` in 0 ..< `count`:
      var `elemVar`: `elemType`
      `elemUnpack`
      `dstAccess`.add(`elemVar`)

proc emitOptionUnpack(dstAccess, srcAccess, userType: NimNode): NimNode =
  ## Rebuild an Option from a wire `ptr`: nil → none, else unpack the pointee.
  let innerType = userType[1]
  let elemVar = genSym(nskVar, "innerVal")
  let elemUnpack = emitElemUnpack(elemVar, nnkBracketExpr.newTree(srcAccess), innerType)
  quote:
    if `srcAccess`.isNil():
      `dstAccess` = none(`innerType`)
    else:
      var `elemVar`: `innerType`
      `elemUnpack`
      `dstAccess` = some(`elemVar`)

proc emitUnpackStmt(
    resultObj, srcObj, fieldNameIdent, userType: NimNode
): seq[NimNode] =
  ## Fill `resultObj.<field>` from `srcObj.<field>`.
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(resultObj, fieldNameIdent)
  if isSeqType(userType):
    return @[emitSeqUnpack(dstAccess, srcObj, fieldNameIdent, userType)]
  @[emitElemUnpack(dstAccess, srcAccess, userType)]

proc emitSeqFree(dstObj, fieldNameIdent, userType: NimNode): NimNode =
  ## Free a seq field: each element (skipped for POD), then the shared buffer.
  let elemType = userType[1]
  let items = seqItemsField(dstObj, fieldNameIdent)
  let count = seqLenField(dstObj, fieldNameIdent)
  let idx = genSym(nskForVar, "i")
  let elemFree = emitElemFree(nnkBracketExpr.newTree(items, idx), elemType)
  let freeLoop =
    if elemFree.kind == nnkEmpty:
      newStmtList()
    else:
      newStmtList(
        nnkForStmt.newTree(
          idx, nnkInfix.newTree(ident("..<"), newLit(0), count), newStmtList(elemFree)
        )
      )
  quote:
    if not `items`.isNil():
      `freeLoop`
      deallocShared(`items`)
      `items` = nil
      `count` = 0

proc emitOptionFree(dstAccess, userType: NimNode): NimNode =
  ## Free an Option field: the pointee (skipped for POD), then the box.
  let innerType = userType[1]
  let freeInner = maybeStmt(emitElemFree(nnkBracketExpr.newTree(dstAccess), innerType))
  quote:
    if not `dstAccess`.isNil():
      `freeInner`
      deallocShared(`dstAccess`)
      `dstAccess` = nil

proc emitFreeStmt(dstObj, fieldNameIdent, userType: NimNode): seq[NimNode] =
  ## Release `dstObj.<field>`: free cstrings/arrays/pointers; POD frees nothing.
  let dstAccess = newDotExpr(dstObj, fieldNameIdent)
  if isSeqType(userType):
    return @[emitSeqFree(dstObj, fieldNameIdent, userType)]
  let elemFree = emitElemFree(dstAccess, userType)
  if elemFree.kind == nnkEmpty:
    return @[]
  @[elemFree]

proc buildCWireProcs(
    userTypeName: string, fieldNames: seq[string], fieldTypes: seq[NimNode]
): seq[NimNode] =
  ## Generate public cwirePack / cwireUnpack / cwireFree procs for `userTypeName`.
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

  @[packProc, unpProc, freeProc]

proc fieldInfoForType(
    typeName: string
): tuple[names: seq[string], types: seq[NimNode]] {.compileTime.} =
  ## Look up an ffi type's fields from the registry, parsing each recorded type.
  for typeMeta in ffiTypeRegistry:
    if typeMeta.name != typeName:
      continue
    var names: seq[string] = @[]
    var types: seq[NimNode] = @[]
    for f in typeMeta.fields:
      names.add(f.name)
      types.add(parseExpr(f.typeName))
    return (names, types)
  error("fieldInfoForType: ffi type '" & typeName & "' not in registry")

proc collectNestedFFITypes(
    fieldTypes: seq[NimNode], deps: var seq[string]
) {.compileTime.} =
  ## Append (deduped) nested ffi type names in `fieldTypes`, recursing through
  ## `seq`/`Option`/`array`/`tuple`.
  for t in fieldTypes:
    if isNestedFFIType(t):
      let n = $t
      if n notin deps:
        deps.add(n)
    elif isSeqType(t) or isOptionType(t):
      collectNestedFFITypes(@[t[1]], deps)
    elif isArrayType(t):
      collectNestedFFITypes(@[t[2]], deps)
    elif isTupleType(t):
      for c in tupleComponents(t):
        collectNestedFFITypes(@[c.typ], deps)

proc ensureCWireFor(typeName: string, sink: NimNode) {.compileTime.} =
  ## Idempotent: append `typeName`'s cwire companion + procs to `sink` if not yet
  ## emitted. Nested ffi deps are ensured first so the AST is self-contained.
  if isCWireEmitted(typeName):
    return
  let info = fieldInfoForType(typeName)
  var deps: seq[string] = @[]
  collectNestedFFITypes(info.types, deps)
  for dep in deps:
    ensureCWireFor(dep, sink)
  markCWireEmitted(typeName)
  let section = newNimNode(nnkTypeSection)
  section.add(buildCWireTypeDef(typeName, info.names, info.types))
  sink.add(section)
  for p in buildCWireProcs(typeName, info.names, info.types):
    sink.add(p)

proc flushCWireCompanions*(): NimNode {.compileTime.} =
  ## Emit the `_CWire` companion + procs for every registered `abi = c` type.
  let sink = newStmtList()
  for typeMeta in ffiTypeRegistry:
    if typeMeta.abiFormat == ABIFormat.C:
      ensureCWireFor(typeMeta.name, sink)
  sink

## abi = c proc dispatch. The foreign surface is CBOR-free (the `_CWire` structs are
## the C ABI) but transport reuses the CBOR request path internally. Emitted at
## `genBindings()` time (after `flushCWireCompanions`) so the companions are in scope.

type
  CAbiKind = enum
    cakMethod
    cakCtor

  CAbiSpec = object
    kind: CAbiKind
    exportName: string ## snake_case C symbol, e.g. "echo_shout"
    libType: NimNode ## library value type, e.g. `Echo`
    envelope: NimNode ## per-proc Req type, e.g. `EchoShoutReq`
    paramNames: seq[string] ## envelope field names (the extra params)
    paramTypes: seq[NimNode] ## envelope field types
    respType: NimNode ## method result T; empty for a ctor

var cAbiSpecs {.compileTime.}: seq[CAbiSpec]

proc copyTypes(types: seq[NimNode]): seq[NimNode] {.compileTime.} =
  var res: seq[NimNode] = @[]
  for t in types:
    res.add(t.copyNimTree())
  res

proc registerCAbiMethod*(
    exportName: string,
    libType, envelope: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
    respType: NimNode,
) {.compileTime.} =
  ## Record an `abi = c` method for `flushCAbiDispatch`. Nodes are `copyNimTree`
  ## frozen: reusing the Req section's originals (bound to `nnkSym`) would ICE.
  cAbiSpecs.add(
    CAbiSpec(
      kind: cakMethod,
      exportName: exportName,
      libType: libType.copyNimTree(),
      envelope: envelope.copyNimTree(),
      paramNames: paramNames,
      paramTypes: copyTypes(paramTypes),
      respType: respType.copyNimTree(),
    )
  )

proc registerCAbiCtor*(
    exportName: string,
    libType, envelope: NimNode,
    paramNames: seq[string],
    paramTypes: seq[NimNode],
) {.compileTime.} =
  ## Record an `abi = c` ctor for `flushCAbiDispatch`; see `registerCAbiMethod`
  ## for why nodes are `copyNimTree` frozen.
  cAbiSpecs.add(
    CAbiSpec(
      kind: cakCtor,
      exportName: exportName,
      libType: libType.copyNimTree(),
      envelope: envelope.copyNimTree(),
      paramNames: paramNames,
      paramTypes: copyTypes(paramTypes),
      respType: newEmptyNode(),
    )
  )

proc cdeclReplyPragma(): NimNode =
  nnkPragma.newTree(
    ident("cdecl"),
    ident("gcsafe"),
    nnkExprColonExpr.newTree(ident("raises"), nnkBracket.newTree()),
  )

proc cAbiCbType(replyType: NimNode): NimNode =
  ## The caller's typed reply callback proc type.
  let fp = nnkFormalParams.newTree(
    newEmptyNode(),
    newIdentDefs(ident("err"), ident("cint")),
    newIdentDefs(ident("reply"), replyType),
    newIdentDefs(ident("errMsg"), ident("cstring")),
    newIdentDefs(ident("ud"), ident("pointer")),
  )
  nnkProcTy.newTree(fp, cdeclReplyPragma())

proc boxTypeDef(boxName, cbType: NimNode): NimNode =
  ## Box object holding the caller's callback + user data across the thread hop.
  let recList = nnkRecList.newTree(
    newIdentDefs(ident("fn"), cbType), newIdentDefs(ident("ud"), ident("pointer"))
  )
  let objTy = nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recList)
  nnkTypeSection.newTree(nnkTypeDef.newTree(boxName, newEmptyNode(), objTy))

proc replyTrampProc(trampName, body: NimNode): NimNode =
  ## `FFICallBack`-shaped proc: runs on the FFI thread, converts the reply, frees the box.
  newProc(
    name = trampName,
    params = @[
      newEmptyNode(),
      newIdentDefs(ident("ret"), ident("cint")),
      newIdentDefs(ident("msg"), nnkPtrTy.newTree(ident("cchar"))),
      newIdentDefs(ident("len"), ident("csize_t")),
      newIdentDefs(ident("ud"), ident("pointer")),
    ],
    body = body,
    pragmas = cdeclReplyPragma(),
  )

proc objectTrampBody(boxName, respType, respWire: NimNode): NimNode =
  ## Reply trampoline for an object return: decode, `cwirePack` into `_CWire`,
  ## hand a pointer to the caller, release. `reply` is nil only on error.
  quote:
    let box = cast[ptr `boxName`](ud)
    if box.isNil():
      return
    if ret == RET_STALE_WARN:
      # Non-terminal progress signal: keep the box, don't decode.
      return
    defer:
      freeBox(box)
    if box.fn.isNil():
      return
    try:
      if ret != RET_OK:
        var em = newString(int(len))
        if int(len) > 0:
          copyMem(addr em[0], msg, int(len))
        box.fn(ret, nil, em.cstring, box.ud)
        return
      let decoded =
        cborDecodePtr(cast[ptr UncheckedArray[byte]](msg), int(len), `respType`)
      if decoded.isErr():
        box.fn(RET_ERR, nil, decoded.error.cstring, box.ud)
      else:
        var wire: `respWire`
        cwirePack(wire, decoded.get())
        box.fn(RET_OK, addr wire, "".cstring, box.ud)
        cwireFree(wire)
    except CatchableError as e:
      box.fn(RET_ERR, nil, e.msg.cstring, box.ud)

proc stringTrampBody(boxName: NimNode): NimNode =
  ## Reply trampoline for a `string` return (and the ctor's address string):
  ## decode and hand the caller a NUL-terminated `cstring`. Reply/error strings
  ## are always non-nil empty on the paths they don't apply to (no nil deref).
  quote:
    let box = cast[ptr `boxName`](ud)
    if box.isNil():
      return
    if ret == RET_STALE_WARN:
      # Non-terminal progress signal: keep the box, don't decode.
      return
    defer:
      freeBox(box)
    if box.fn.isNil():
      return
    try:
      if ret != RET_OK:
        var em = newString(int(len))
        if int(len) > 0:
          copyMem(addr em[0], msg, int(len))
        box.fn(ret, "".cstring, em.cstring, box.ud)
        return
      let decoded = cborDecodePtr(cast[ptr UncheckedArray[byte]](msg), int(len), string)
      if decoded.isErr():
        box.fn(RET_ERR, "".cstring, decoded.error.cstring, box.ud)
      else:
        let replyStr = decoded.get()
        box.fn(RET_OK, replyStr.cstring, "".cstring, box.ud)
    except CatchableError as e:
      box.fn(RET_ERR, "".cstring, e.msg.cstring, box.ud)

proc exportedMethodProc(
    spec: CAbiSpec, boxName, envWire, trampName, poolIdent, cbType: NimNode
): NimNode =
  # No `foreignThreadGc`: `cwireUnpack`/`cborEncodeShared` alloc on the calling thread (already GC-registered); wrapping would free its live ORC heap.
  let envName = spec.envelope
  let libFFICtx =
    nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), spec.libType))
  # String reply: empty non-nil cstring on error; object reply: nil ptr gated by err_code.
  let emptyReply =
    if isStringType(spec.respType):
      newDotExpr(newLit(""), ident("cstring"))
    else:
      newNilLit()
  let body = quote:
    if onReply.isNil():
      return RET_MISSING_CALLBACK
    if not `poolIdent`.isValidCtx(cast[pointer](ctx)):
      onReply(RET_ERR, `emptyReply`, "ctx is not a valid FFI context".cstring, userData)
      return RET_ERR
    var reqObj: `envName` = cwireUnpack(req[])
    let enc = cborEncodeShared(reqObj)
    let reqBuf = enc.data
    let reqBufLen = enc.len
    let box = cast[ptr `boxName`](allocBox(sizeof(`boxName`)))
    box.fn = onReply
    box.ud = userData
    let typeStr = $`envName`
    let reqPtr = FFIThreadRequest.initFromOwnedShared(
      `trampName`, box, typeStr.cstring, reqBuf, reqBufLen
    )
    let sendRes =
      try:
        ffi_context.sendRequestToFFIThread(ctx, reqPtr)
      except Exception as e:
        Result[void, string].err("sendRequestToFFIThread exception: " & e.msg)
    if sendRes.isErr():
      onReply(RET_ERR, `emptyReply`, sendRes.error.cstring, userData)
      return RET_ERR
    return RET_OK
  newProc(
    name = ident($envName & "CAbiExport"),
    params = @[
      ident("cint"),
      newIdentDefs(ident("ctx"), libFFICtx),
      newIdentDefs(ident("onReply"), cbType),
      newIdentDefs(ident("userData"), ident("pointer")),
      newIdentDefs(ident("req"), nnkPtrTy.newTree(envWire)),
    ],
    body = body,
    pragmas = nnkPragma.newTree(
      ident("dynlib"),
      nnkExprColonExpr.newTree(ident("exportc"), newStrLitNode(spec.exportName)),
      ident("cdecl"),
      nnkExprColonExpr.newTree(ident("raises"), nnkBracket.newTree()),
    ),
  )

proc exportedCtorProc(
    spec: CAbiSpec, boxName, envWire, trampName, poolIdent, cbType: NimNode
): NimNode =
  let envName = spec.envelope
  # No `foreignThreadGc` (see exportedMethodProc). initGuard is built as raw AST because a `when declared` over an undeclared symbol inside `quote` ICEs.
  let initGuard = nnkWhenStmt.newTree(
    nnkElifBranch.newTree(
      newCall(ident("declared"), ident("initializeLibrary")),
      newStmtList(newCall(ident("initializeLibrary"))),
    )
  )
  let body = quote:
    let ctxRes = `poolIdent`.createFFIContext()
    if ctxRes.isErr():
      if not onCreated.isNil():
        onCreated(
          RET_ERR,
          "".cstring,
          ("ffiCtor: failed to create FFIContext: " & $ctxRes.error).cstring,
          userData,
        )
      return nil
    let ctx = ctxRes.get()
    var reqObj: `envName` = cwireUnpack(req[])
    let enc = cborEncodeShared(reqObj)
    let reqBuf = enc.data
    let reqBufLen = enc.len
    let box = cast[ptr `boxName`](allocBox(sizeof(`boxName`)))
    box.fn = onCreated
    box.ud = userData
    let typeStr = $`envName`
    let reqPtr = FFIThreadRequest.initFromOwnedShared(
      `trampName`, box, typeStr.cstring, reqBuf, reqBufLen
    )
    let sendRes =
      try:
        ctx.sendRequestToFFIThread(reqPtr)
      except Exception as e:
        Result[void, string].err("sendRequestToFFIThread exception: " & e.msg)
    if sendRes.isErr():
      if not onCreated.isNil():
        onCreated(RET_ERR, "".cstring, sendRes.error.cstring, userData)
      return nil
    return cast[pointer](ctx)
  body.insert(0, initGuard)
  newProc(
    name = ident($envName & "CAbiExport"),
    params = @[
      ident("pointer"),
      newIdentDefs(ident("req"), nnkPtrTy.newTree(envWire)),
      newIdentDefs(ident("onCreated"), cbType),
      newIdentDefs(ident("userData"), ident("pointer")),
    ],
    body = body,
    pragmas = nnkPragma.newTree(
      ident("dynlib"),
      nnkExprColonExpr.newTree(ident("exportc"), newStrLitNode(spec.exportName)),
      ident("cdecl"),
      nnkExprColonExpr.newTree(ident("raises"), nnkBracket.newTree()),
    ),
  )

proc ensureCWireForFields(
    sink: NimNode, typeName: string, names: seq[string], types: seq[NimNode]
) {.compileTime.} =
  ## Emit the `_CWire` companion + procs for a synthetic per-proc Req envelope
  ## (not a user `{.ffi.}` type, so not in `ffiTypeRegistry`).
  if isCWireEmitted(typeName):
    return
  var deps: seq[string] = @[]
  collectNestedFFITypes(types, deps)
  for dep in deps:
    ensureCWireFor(dep, sink)
  markCWireEmitted(typeName)
  let section = newNimNode(nnkTypeSection)
  section.add(buildCWireTypeDef(typeName, names, types))
  sink.add(section)
  for p in buildCWireProcs(typeName, names, types):
    sink.add(p)

proc flushCAbiDispatch*(): NimNode {.compileTime.} =
  ## Emit the exported wrappers + reply trampolines for every registered
  ## `abi = c` proc. Runs after `flushCWireCompanions`.
  let sink = newStmtList()
  for spec in cAbiSpecs:
    let envName = spec.envelope
    ensureCWireForFields(sink, $envName, spec.paramNames, spec.paramTypes)
    let envWire = ident(cwireTypeName($envName))
    let boxName = ident($envName & "CBox")
    let trampName = ident($envName & "CReply")
    let poolIdent = ident($spec.libType & "FFIPool")
    case spec.kind
    of cakCtor:
      let cbType = cAbiCbType(ident("cstring"))
      sink.add(boxTypeDef(boxName, cbType))
      sink.add(replyTrampProc(trampName, stringTrampBody(boxName)))
      sink.add(exportedCtorProc(spec, boxName, envWire, trampName, poolIdent, cbType))
    of cakMethod:
      let rt = spec.respType
      if isStringType(rt):
        let cbType = cAbiCbType(ident("cstring"))
        sink.add(boxTypeDef(boxName, cbType))
        sink.add(replyTrampProc(trampName, stringTrampBody(boxName)))
        sink.add(
          exportedMethodProc(spec, boxName, envWire, trampName, poolIdent, cbType)
        )
      elif rt.kind == nnkIdent:
        let respWire = ident(cwireTypeName($rt))
        let cbType = cAbiCbType(nnkPtrTy.newTree(respWire))
        sink.add(boxTypeDef(boxName, cbType))
        sink.add(replyTrampProc(trampName, objectTrampBody(boxName, rt, respWire)))
        sink.add(
          exportedMethodProc(spec, boxName, envWire, trampName, poolIdent, cbType)
        )
      else:
        error(
          "abi = c: unsupported response type for proc '" & spec.exportName & "': " &
            rt.repr & " (only object and string returns are wired)"
        )
  sink
