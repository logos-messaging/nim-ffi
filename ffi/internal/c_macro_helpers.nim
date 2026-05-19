## Compile-time helpers used by `ffi_macro.nim` when `-d:ffiMode=raw`.
##
## When the raw ABI is active, for every {.ffi.} object type T and every
## per-proc Req/Resp we generate a parallel `T_CWire` Nim object whose
## field layout matches the C struct emitted by `ffi/codegen/c.nim`:
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

import std/[macros, strutils, tables]
import ../codegen/meta

proc isPureCMode*(): bool {.compileTime.} =
  ## True iff the active ABI mode is the in-process flat C-struct one
  ## (`-d:ffiMode=raw`). Read at macro-expansion time so that
  ## `.ffi.`/`.ffiCtor.`/`.ffiDtor.` emission can pick the wire-struct
  ## shim variant. The consumer-side wrapper language (`ffiLang`) is
  ## intentionally *not* consulted here — the Nim-side ABI is the same
  ## whether the consumer wrapper is C++, Rust, or anything else built
  ## atop the same flat C structs.
  return effectiveMode() == "raw"

# ---------------------------------------------------------------------------
# Compile-time registry of known ffi-type names → used to recognise nested
# user types so the wire form can use their `_CWire` companion.
# ---------------------------------------------------------------------------

proc knownFFITypeNames*(): seq[string] {.compileTime.} =
  var names: seq[string] = @[]
  for t in ffiTypeRegistry:
    names.add(t.name)
  return names

proc isKnownFFIType(name: string): bool {.compileTime.} =
  for t in ffiTypeRegistry:
    if t.name == name:
      return true
  return false

# ---------------------------------------------------------------------------
# Tracking which cwire companion types have already been emitted in the
# current compilation. Because `{.ffi.}` on a type cannot emit a multi-stmt
# expansion (Nim's macro contract for type-pragmas only accepts a TypeDef
# back), cwire emission is performed lazily by whichever site references
# the type first — usually `registerReqFFI` for a `.ffi.`/`.ffiCtor.` proc.
# The `genBindings()` call at end-of-file picks up any stragglers.
# ---------------------------------------------------------------------------

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
  return found

proc markCWireEmitted*(typeName: string) {.compileTime.} =
  if not isCWireEmitted(typeName):
    emittedCWireTypes.add(typeName)

# ---------------------------------------------------------------------------
# Type-level helpers
# ---------------------------------------------------------------------------

proc cwireTypeName*(userTypeName: string): string =
  ## Companion-type naming convention. Kept stable so generated tests can
  ## reach in by name.
  return userTypeName & "_CWire"

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
  return userType

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
  return @[newIdentDefs(ident(fieldName), wireFieldType(fieldType), newEmptyNode())]

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
  return newTree(nnkTypeDef, postfix(wireName, "*"), newEmptyNode(), objTy)

proc buildCWireType*(
    userTypeName: string, fieldNames: seq[string], fieldTypes: seq[NimNode]
): NimNode =
  ## Convenience wrapper: returns the TypeDef inside its own TypeSection.
  return newNimNode(nnkTypeSection).add(
      buildCWireTypeDef(userTypeName, fieldNames, fieldTypes)
    )

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
  return newAssignment(dstElem, srcElem)

proc emitElemUnpack(dstElem, srcElem, elemType: NimNode): NimNode =
  if isStringType(elemType):
    return newAssignment(dstElem, newCall(ident("$"), srcElem))
  if isNestedFFIType(elemType):
    return newAssignment(dstElem, newCall(ident("cwireUnpack"), srcElem))
  return newAssignment(dstElem, srcElem)

proc emitElemFree(elemAccess, elemType: NimNode): NimNode =
  if isStringType(elemType):
    return newCall(ident("cwireFreeStr"), elemAccess)
  if isNestedFFIType(elemType):
    return newCall(ident("cwireFree"), elemAccess)
  return newEmptyNode()

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
  return stmts

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
  return stmts

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
  return stmts

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

  return @[packProc, unpProc, freeProc, thunkProc]

# ---------------------------------------------------------------------------
# Top-level entry: given the AST of an {.ffi.} object type, return a
# StmtList with the companion type + procs (or an empty StmtList for the
# non-C path).
# ---------------------------------------------------------------------------

proc cwireExtrasForFFIType*(
    typeDef: NimNode
): tuple[wireType: NimNode, procs: seq[NimNode]] =
  ## Inspect `typeDef` (an nnkTypeDef of a registered `.ffi.` object type)
  ## and return the bare wire TypeDef alongside the three conversion procs.
  ## The caller decides how to splice them — typically: append the wire
  ## TypeDef to the same TypeSection that holds the user type so the AST
  ## that hits Nim is a single well-formed `type T1=…; T2=…` section
  ## followed by the procs.
  ##
  ## When the C target is inactive, returns `(nil, @[])` so callers can
  ## unconditionally check `result.wireType.isNil`.
  if not isPureCMode():
    return (nil, @[])

  let typeName =
    if typeDef[0].kind == nnkPostfix:
      $typeDef[0][1]
    else:
      $typeDef[0]

  var fieldNames: seq[string] = @[]
  var fieldTypes: seq[NimNode] = @[]

  let objTy = typeDef[2]
  if objTy.kind == nnkObjectTy and objTy.len >= 3:
    let recList = objTy[2]
    if recList.kind == nnkRecList:
      for identDef in recList:
        if identDef.kind == nnkIdentDefs:
          let fieldType = identDef[^2]
          for i in 0 ..< identDef.len - 2:
            fieldNames.add($identDef[i])
            fieldTypes.add(fieldType)

  result.wireType = buildCWireTypeDef(typeName, fieldNames, fieldTypes)
  result.procs = buildCWireProcs(typeName, fieldNames, fieldTypes)

proc cwireExtrasForReqType*(
    reqTypeName: string, paramNames: seq[string], paramTypes: seq[NimNode]
): tuple[wireType: NimNode, procs: seq[NimNode]] =
  ## Same as cwireExtrasForFFIType but driven by the explicit param-list form
  ## used by the {.ffi.}/{.ffiCtor.} macros when they synthesise per-proc
  ## Req types.
  if not isPureCMode():
    return (nil, @[])
  result.wireType = buildCWireTypeDef(reqTypeName, paramNames, paramTypes)
  result.procs = buildCWireProcs(reqTypeName, paramNames, paramTypes)

# ---------------------------------------------------------------------------
# Helper to collect nested type dependencies (transitively).
# ---------------------------------------------------------------------------

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
  for tm in ffiTypeRegistry:
    if tm.name == typeName:
      for f in tm.fields:
        result.names.add(f.name)
        result.types.add(parseExpr(f.typeName))
      return
  error("ensureCWireFor: ffi type '" & typeName & "' not in registry")

proc ensureCWireFor*(typeName: string, sink: NimNode) {.compileTime.} =
  ## Idempotent: if `typeName`'s cwire companion has not yet been emitted,
  ## append its TypeSection and conversion procs to `sink` (an
  ## nnkStmtList) and mark it emitted. Recursively ensures nested ffi
  ## types so that the resulting AST is self-contained.
  ##
  ## Used by `registerReqFFI` (called from `.ffi.`/`.ffiCtor.` macros) to
  ## materialise wire companions for every {.ffi.} type a proc touches —
  ## without depending on the `genBindings()` end-of-file emission.
  if not isPureCMode():
    return
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
