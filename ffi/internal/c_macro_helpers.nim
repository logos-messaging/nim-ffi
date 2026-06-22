## Compile-time helpers used by `ffi_macro.nim` for the `c` (flat C-struct) ABI.
## For each `{.ffi: "abi = c".}` object T, emits a `T_CWire` companion plus
## `cwirePack` / `cwireUnpack` / `cwireFree`. Field mapping: `string`→`cstring`,
## `seq[T]`→`<name>_items`+`<name>_len`, `Option[T]`/`Maybe[T]`→`ptr T_w`
## (nil=none), nested {.ffi.}→`T_CWire`, POD unchanged; seq/Option nest to any
## depth, but a `seq` may not nest inside seq/Option (no single-field form).

import std/macros
import ../codegen/meta

const
  cwireItemsSuffix = "_items"
  cwireLenSuffix = "_len"

var emittedCWireTypes {.compileTime.}: seq[string]

proc isCWireEmitted(typeName: string): bool {.compileTime.} =
  ## Indexed scan: works around a Nim 2.2 compile-time VM quirk where `for x in
  ## seq` over a freshly-mutated `{.compileTime.}` seq goes stale.
  var found = false
  for i in 0 ..< emittedCWireTypes.len:
    if emittedCWireTypes[i] == typeName:
      found = true
      break
  found

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

proc isKnownFFIType(name: string): bool {.compileTime.} =
  for typeMeta in ffiTypeRegistry:
    if typeMeta.name == name:
      return true
  false

proc isNestedFFIType(t: NimNode): bool =
  t.kind == nnkIdent and isKnownFFIType($t)

proc wireValueType(t: NimNode): NimNode =
  ## Single-field wire form of value type `t`: `string`→`cstring`, nested
  ## {.ffi.}→`T_CWire`, `Option[T]`→`ptr <wireOf T>`, POD unchanged. `seq`
  ## has no single-field form, so it errors here (see `wireFieldsFor`).
  if isStringType(t):
    return ident("cstring")
  if isNestedFFIType(t):
    return ident(cwireTypeName($t))
  if isOptionType(t):
    return nnkPtrTy.newTree(wireValueType(t[1]))
  if isSeqType(t):
    error("cwire: `seq` cannot be nested inside seq/Option: " & t.repr)
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

proc emitElemPack(dstElem, srcElem, elemType: NimNode): NimNode =
  ## Pack one value: cstring for `string`, recursive `cwirePack` for nested
  ## ffi types, recursive Option handling, direct copy for POD.
  if isStringType(elemType):
    return newAssignment(dstElem, newCall(ident("cwireAllocStr"), srcElem))
  if isNestedFFIType(elemType):
    return newCall(ident("cwirePack"), dstElem, srcElem)
  if isOptionType(elemType):
    return emitOptionPack(dstElem, srcElem, elemType)
  if isSeqType(elemType):
    error("cwire: `seq` cannot be nested inside seq/Option: " & elemType.repr)
  newAssignment(dstElem, srcElem)

proc emitElemUnpack(dstElem, srcElem, elemType: NimNode): NimNode =
  ## Inverse of `emitElemPack`: copy one value back into Nim-managed memory.
  if isStringType(elemType):
    return newAssignment(dstElem, newCall(ident("$"), srcElem))
  if isNestedFFIType(elemType):
    return newAssignment(dstElem, newCall(ident("cwireUnpack"), srcElem))
  if isOptionType(elemType):
    return emitOptionUnpack(dstElem, srcElem, elemType)
  if isSeqType(elemType):
    error("cwire: `seq` cannot be nested inside seq/Option: " & elemType.repr)
  newAssignment(dstElem, srcElem)

proc emitElemFree(elemAccess, elemType: NimNode): NimNode =
  ## Free one value, or `nnkEmpty` for POD (nothing to free).
  if isStringType(elemType):
    return newCall(ident("cwireFreeStr"), elemAccess)
  if isNestedFFIType(elemType):
    return newCall(ident("cwireFree"), elemAccess)
  if isOptionType(elemType):
    return emitOptionFree(elemAccess, elemType)
  if isSeqType(elemType):
    error("cwire: `seq` cannot be nested inside seq/Option: " & elemType.repr)
  newEmptyNode()

proc maybeStmt(n: NimNode): NimNode =
  ## `n` as a one-statement list, or an empty list when `n` is `nnkEmpty`
  ## (nothing to do) — keeps the surrounding `quote` block well-formed.
  if n.kind == nnkEmpty:
    return newStmtList()
  newStmtList(n)

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
  ## none → nil.
  let innerType = userType[1]
  let wireInner = wireValueType(innerType)
  let bufType = nnkPtrTy.newTree(wireInner)
  let elemPack = emitElemPack(
    nnkBracketExpr.newTree(dstAccess), newCall(ident("get"), srcAccess), innerType
  )
  quote:
    if `srcAccess`.isSome():
      `dstAccess` = cast[`bufType`](allocShared(sizeof(`wireInner`)))
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
  ## `fieldTypes`, recursing through `seq`/`Option`/`Maybe` to any depth.
  for t in fieldTypes:
    if isNestedFFIType(t):
      let n = $t
      if n notin deps:
        deps.add(n)
    elif isSeqType(t) or isOptionType(t):
      collectNestedFFITypes(@[t[1]], deps)

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
