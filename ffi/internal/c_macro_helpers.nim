## Compile-time helpers used by `ffi_macro.nim` for the `c` (flat C-struct) ABI.
## For each `{.ffi: "abi = c".}` object T, emits a `T_CWire` companion plus
## `cwirePack` / `cwireUnpack` / `cwireFree`. Field mapping: `string`→`cstring`,
## `seq[T]`→`<name>_items`+`<name>_len`, `Option[T]`/`Maybe[T]`→`ptr T_w`
## (nil=none), nested {.ffi.}→`T_CWire`, `array[N, T]`→inline `array[N, T_w]`,
## `tuple[a: T, ...]`→`tuple[a: T_w, ...]`, POD unchanged. seq/Option/array/tuple
## nest to any depth, but a `seq` may not nest inside another container (it has
## no single-field wire form — only the top-level `_items`/`_len` split).

import std/macros
import ../codegen/meta

const
  cwireItemsSuffix = "_items"
  cwireLenSuffix = "_len"

var emittedCWireTypes {.compileTime.}: seq[string]

proc isCWireEmitted(typeName: string): bool {.compileTime.} =
  ## Indexed scan: works around a Nim 2.2 compile-time VM quirk where `for x in
  ## seq` over a freshly-mutated `{.compileTime.}` seq goes stale.
  for i in 0 ..< emittedCWireTypes.len:
    if emittedCWireTypes[i] == typeName:
      return true
  false

proc markCWireEmitted(typeName: string) {.compileTime.} =
  if not isCWireEmitted(typeName):
    emittedCWireTypes.add(typeName)

proc cwireTypeName(userTypeName: string): string =
  ## Companion-type naming convention; stable so generated tests reach in by name.
  userTypeName & "_CWire"

proc seqItemsField(obj, field: NimNode): NimNode =
  ## `obj.<field>_items` — the buffer half of a seq's two-field wire split.
  newDotExpr(obj, ident($field & cwireItemsSuffix))

proc seqLenField(obj, field: NimNode): NimNode =
  ## `obj.<field>_len` — the count half of a seq's two-field wire split.
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
  ## Flatten a named-tuple type into `(name, type)` pairs, expanding grouped
  ## declarations like `tuple[a, b: int]` into one entry per name.
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
    if typeMeta.name == name:
      return true
  false

proc isNestedFFIType(t: NimNode): bool =
  t.kind == nnkIdent and isKnownFFIType($t)

proc cwireNeedsFree(t: NimNode): bool =
  ## Whether the wire form of `t` owns shared-memory allocations that
  ## `cwireFree` must release. POD scalars (and aggregates entirely of POD)
  ## own nothing, so their free is elided.
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
  ## `seq` has no single-field wire form (only the top-level `_items`/`_len`
  ## split), so it can't sit inside another container. One message, one place.
  error(
    "cwire: `seq` has no single-field wire form, so it can't nest inside " &
      "another container (use it only as a top-level field): " & t.repr
  )

proc wireValueType(t: NimNode): NimNode =
  ## Single-field wire form of value type `t`: `string`→`cstring`, nested
  ## {.ffi.}→`T_CWire`, `Option[T]`→`ptr <wireOf T>`, `array[N, T]`→
  ## `array[N, <wireOf T>]`, `tuple[a: T, ...]`→`tuple[a: <wireOf T>, ...]`,
  ## POD unchanged. `seq` has no single-field form, so it errors here.
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
  ## IdentDefs for one field. `seq[T]` splits into `<name>_items: ptr
  ## UncheckedArray[<wireOf T>]` + `<name>_len: int`; else a single IdentDef.
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
  ## Build the bare `nnkTypeDef` (no enclosing TypeSection) for the wire
  ## companion of `userTypeName`.
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
  ## Pack one value: cstring for `string`, recursive `cwirePack` for nested
  ## ffi types, recursive Option/array/tuple handling, direct copy for POD.
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
  ## Inverse of `emitElemPack`: copy one value back into Nim-managed memory.
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
  ## Free one value, or `nnkEmpty` for POD (nothing to free).
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
  ## `n` as a one-statement list, or an empty list when `n` is `nnkEmpty`
  ## (nothing to do) — keeps the surrounding `quote` block well-formed.
  if n.kind == nnkEmpty:
    return newStmtList()
  newStmtList(n)

proc indexLoop(access, idx, body: NimNode): NimNode =
  ## `for <idx> in low(access) .. high(access): body` — `low`/`high` so any
  ## array index range (not just 0-based) is covered.
  nnkForStmt.newTree(
    idx,
    nnkInfix.newTree(
      ident(".."), newCall(ident("low"), access), newCall(ident("high"), access)
    ),
    newStmtList(body),
  )

proc emitArrayPack(dstAccess, srcAccess, arrType: NimNode): NimNode =
  ## Pack a fixed `array[N, T]` element-by-element into the inline wire array;
  ## the array itself needs no allocation, only its GC'd element contents do.
  let idx = genSym(nskForVar, "i")
  let body = emitElemPack(
    nnkBracketExpr.newTree(dstAccess, idx),
    nnkBracketExpr.newTree(srcAccess, idx),
    arrType[2],
  )
  indexLoop(srcAccess, idx, body)

proc emitArrayUnpack(dstAccess, srcAccess, arrType: NimNode): NimNode =
  ## Inverse of `emitArrayPack`: copy each wire element back into the Nim array.
  let idx = genSym(nskForVar, "i")
  let body = emitElemUnpack(
    nnkBracketExpr.newTree(dstAccess, idx),
    nnkBracketExpr.newTree(srcAccess, idx),
    arrType[2],
  )
  indexLoop(srcAccess, idx, body)

proc emitArrayFree(dstAccess, arrType: NimNode): NimNode =
  ## Free each array element; `nnkEmpty` when the element type owns nothing.
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
  ## Inverse of `emitTuplePack`: copy each wire component back out.
  let body = newStmtList()
  for c in tupleComponents(tupType):
    let nm = ident(c.name)
    body.add(
      emitElemUnpack(newDotExpr(dstAccess, nm), newDotExpr(srcAccess, nm), c.typ)
    )
  body

proc emitTupleFree(dstAccess, tupType: NimNode): NimNode =
  ## Free each tuple component that owns allocations; `nnkEmpty` when none do.
  if not cwireNeedsFree(tupType):
    return newEmptyNode()
  let body = newStmtList()
  for c in tupleComponents(tupType):
    body.add(maybeStmt(emitElemFree(newDotExpr(dstAccess, ident(c.name)), c.typ)))
  body

proc emitSeqPack(dstObj, srcAccess, fieldNameIdent, userType: NimNode): NimNode =
  ## Pack a seq field into a freshly `allocShared`'d `UncheckedArray`; an empty
  ## seq encodes as nil items + 0 len.
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
  ## Pack an Option into a `ptr`: some → `allocShared` a box and pack into it,
  ## none → nil. The payload is read into a local once, so a composite inner
  ## type (e.g. `array`/`tuple`) isn't re-`get()`-copied per element.
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
  ## Populate `dstObj.<field>` from `srcObj.<field>`, allocating shared-memory
  ## cstrings/arrays as the field's natural type requires.
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(dstObj, fieldNameIdent)
  if isSeqType(userType):
    return @[emitSeqPack(dstObj, srcAccess, fieldNameIdent, userType)]
  @[emitElemPack(dstAccess, srcAccess, userType)]

proc emitSeqUnpack(dstAccess, srcObj, fieldNameIdent, userType: NimNode): NimNode =
  ## Rebuild a Nim seq from the `<field>_items`/`_len` wire pair.
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
  ## Fill `resultObj.<field>` from `srcObj.<field>`, copying back into
  ## Nim-managed memory.
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(resultObj, fieldNameIdent)
  if isSeqType(userType):
    return @[emitSeqUnpack(dstAccess, srcObj, fieldNameIdent, userType)]
  @[emitElemUnpack(dstAccess, srcAccess, userType)]

proc emitSeqFree(dstObj, fieldNameIdent, userType: NimNode): NimNode =
  ## Free a seq field: free each element (skipped entirely for POD), then the
  ## shared buffer.
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
  ## Free an Option field: free the pointee (skipped for POD), then the box.
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
  ## Generate cwirePack / cwireUnpack / cwireFree procs for `userTypeName`. All
  ## three are public (`*`) so the macro-expanded code can call them.
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
  ## Look up an ffi type's fields from the compile-time registry and parse each
  ## field's recorded type back into a NimNode AST.
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
  ## Append (deduped) the names of nested ffi types referenced anywhere in
  ## `fieldTypes`, recursing through `seq`/`Option`/`array`/`tuple` to any depth.
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
  ## Idempotent: if `typeName`'s cwire companion has not yet been emitted,
  ## append its TypeSection and conversion procs to `sink` and mark it emitted.
  ## Nested ffi deps are ensured first so the resulting AST is self-contained.
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
  ## Emit the `_CWire` companion + conversion procs for every registered
  ## `abi = c` type. Called by `genBindings()` (a type-pragma macro can't).
  let sink = newStmtList()
  for typeMeta in ffiTypeRegistry:
    if typeMeta.abiFormat == ABIFormat.C:
      ensureCWireFor(typeMeta.name, sink)
  sink
