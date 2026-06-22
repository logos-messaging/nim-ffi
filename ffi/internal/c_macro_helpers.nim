## Compile-time helpers used by `ffi_macro.nim` for the `c` (flat C-struct)
## ABI — i.e. for `{.ffi: "abi = c".}` types.
##
## For every such {.ffi.} object type T (and every per-proc Req/Resp) we
## generate a parallel `T_CWire` Nim object whose field layout matches a flat
## C struct:
##   - `string` → `cstring`
##   - `seq[T]` → two adjacent fields `<name>_items: ptr UncheckedArray[T_w]`
##     and `<name>_len: int`
##   - `Option[T]`/`Maybe[T]` → `<name>: ptr T_w` (nil = none)
##   - Nested {.ffi.} object T → field of type `T_CWire` (by value)
##   - POD → unchanged
##
## Alongside each `_CWire` we emit three runtime procs:
##   - `cwirePack(dst: var T_CWire, src: T)`   — allocates shared cstrings
##   - `cwireUnpack(src: T_CWire): T`          — copies back into Nim heap
##   - `cwireFree(dst: var T_CWire)`           — releases shared cstrings
##
## Wire structs live in `allocShared` memory so they can travel from the
## C caller's thread through the FFI channel without crossing GC boundaries.

import std/macros
import ../codegen/meta

# Which types get a cwire companion is decided per-annotation (`abi == C`) by
# the callers (the `{.ffi.}` type macro registers the abi; `genBindings` flushes
# the companions for every `abiFormat == C` type). The builders below therefore
# emit unconditionally when invoked — there is no global mode switch.

# ---------------------------------------------------------------------------
# Compile-time registry of known ffi-type names → used to recognise nested
# user types so the wire form can use their `_CWire` companion.
# ---------------------------------------------------------------------------

proc isKnownFFIType(name: string): bool {.compileTime.} =
  for t in ffiTypeRegistry:
    if t.name == name:
      return true
  false

# Tracks which cwire companion types have already been emitted this
# compilation. A `{.ffi.}` type-pragma can only return a TypeDef (no multi-stmt
# expansion), so the companions are emitted out-of-band by `genBindings()`,
# which dedupes against this tracker.
var emittedCWireTypes* {.compileTime.}: seq[string]

proc isCWireEmitted*(typeName: string): bool {.compileTime.} =
  ## Linear scan over the emission tracker. Written as an indexed loop to
  ## sidestep a Nim 2.2 compile-time VM quirk where repeated `for x in
  ## seq` reads of a freshly-mutated `{.compileTime.}` seq can return
  ## stale results within a single macro expansion.
  var found = false
  for i in 0 ..< emittedCWireTypes.len:
    if emittedCWireTypes[i] == typeName:
      found = true
      break
  found

proc markCWireEmitted*(typeName: string) {.compileTime.} =
  if not isCWireEmitted(typeName):
    emittedCWireTypes.add(typeName)

# ---------------------------------------------------------------------------
# Type-level helpers
# ---------------------------------------------------------------------------

proc cwireTypeName*(userTypeName: string): string =
  ## Companion-type naming convention. Kept stable so generated tests can
  ## reach in by name.
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
  ## Map a user field type AST → its wire-form AST.
  ## Note: `seq` is not handled here because it must split into two physical
  ## fields; the caller uses `wireFieldsFor` for that case.
  if isStringType(userType):
    return ident("cstring")
  if isOptionType(userType):
    # Option[T] becomes `ptr <wireOf T>` (nil = none).
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
  ## Build the IdentDefs (one or two) that represent `fieldName: fieldType`
  ## in the wire object. Empty pragma + empty default so the result drops
  ## directly into a `nnkRecList`.
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
  ## Build the bare `nnkTypeDef` (no enclosing TypeSection) for the wire
  ## companion of `userTypeName`. Callers splice the result into whichever
  ## TypeSection makes sense at the call site.
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

# ---------------------------------------------------------------------------
# Conversion procs (cwirePack / cwireUnpack / cwireFree)
# ---------------------------------------------------------------------------

proc emitElemPack(dstElem, srcElem, elemType: NimNode): NimNode =
  ## Single-element pack used inside the seq/Option emitters. Mirrors the
  ## field-level rules: cstring for `string`, recursive `cwirePack` for
  ## nested ffi types, direct copy for POD.
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
  ## AST stmts that populate `dstObj.<field>` from `srcObj.<field>` according
  ## to the field's natural-Nim type, allocating shared-memory cstrings and
  ## arrays as needed. Multi-statement for seq/Option.
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

  # POD: direct copy.
  stmts.add(newAssignment(dstAccess, srcAccess))
  stmts

proc emitUnpackStmt(
    resultObj, srcObj, fieldNameIdent, userType: NimNode
): seq[NimNode] =
  ## AST stmts that fill `resultObj.<field>` from `srcObj.<field>`.
  var stmts: seq[NimNode] = @[]
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(resultObj, fieldNameIdent)

  if isStringType(userType):
    # `$cstring` copies into Nim-managed memory.
    let dollar = newCall(ident("$"), srcAccess)
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

  # POD: nothing to free.
  stmts

proc buildCWireProcs*(
    userTypeName: string, fieldNames: seq[string], fieldTypes: seq[NimNode]
): seq[NimNode] =
  ## Generate cwirePack / cwireUnpack / cwireFree procs for `userTypeName`.
  ## All three are public (`*`) so the macro-expanded shim in the user's
  ## module can call them across module boundaries.
  let userName = ident(userTypeName)
  let wireName = ident(cwireTypeName(userTypeName))

  # --- cwirePack(dst: var T_CWire, src: T) ---
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

  # --- cwireUnpack(src: T_CWire): T ---
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

  # --- cwireFree(dst: var T_CWire) ---
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

  # --- cwireFreePtr_<T>(p: pointer) — pointer-typed thunk used by the
  # shim's CleanupProc slot. Named (not anonymous) so it can be picked up
  # by `nimcall` ABI which forbids closures.
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
  ## Append the *names* of any nested ffi types referenced by `fieldTypes`
  ## to `deps` (deduped). Recognises bare ident refs as well as one level
  ## of `seq[X]` / `Option[X]` / `Maybe[X]`. Used by the macro to schedule
  ## cwire emission for the right types before referencing them.
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
  ## Look up an ffi type's fields from the compile-time registry and parse
  ## each field's recorded type back into a NimNode AST.
  var info: tuple[names: seq[string], types: seq[NimNode]]
  for tm in ffiTypeRegistry:
    if tm.name == typeName:
      for f in tm.fields:
        info.names.add(f.name)
        info.types.add(parseExpr(f.typeName))
      return info
  error("ensureCWireFor: ffi type '" & typeName & "' not in registry")

proc ensureCWireFor*(typeName: string, sink: NimNode) {.compileTime.} =
  ## Idempotent: if `typeName`'s cwire companion has not yet been emitted,
  ## append its TypeSection and conversion procs to `sink` (an nnkStmtList),
  ## recursing into nested ffi types first so the result is self-contained.
  ## Called by `genBindings()` to flush a companion for every `abi = c` type.
  if isCWireEmitted(typeName):
    return

  let info = fieldInfoForType(typeName)

  # Emit dependencies first.
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
