## Compile-time helpers used by `ffi_macro.nim` for the `c` (flat C-struct) ABI.
## For each `{.ffi: "abi = c".}` object T, emits a `T_CWire` companion (`string`
## → `cstring`, POD unchanged) plus `cwirePack` / `cwireUnpack` / `cwireFree`.

import std/macros
import ../codegen/meta

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

proc isStringType(t: NimNode): bool =
  t.kind == nnkIdent and ($t == "string" or $t == "cstring")

proc wireFieldType(userType: NimNode): NimNode =
  ## Map a user field type AST → its wire-form AST: `string` → `cstring`,
  ## everything else unchanged.
  if isStringType(userType):
    return ident("cstring")
  userType

proc wireFieldsFor(fieldName: string, fieldType: NimNode): seq[NimNode] =
  ## IdentDefs for `fieldName: fieldType` in the wire object. A seq because
  ## composite fields later split into two physical fields.
  @[newIdentDefs(ident(fieldName), wireFieldType(fieldType), newEmptyNode())]

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

proc emitPackStmt(dstObj, srcObj, fieldNameIdent, userType: NimNode): seq[NimNode] =
  ## Populate `dstObj.<field>` from `srcObj.<field>`: cstring allocation for
  ## strings, direct copy for POD.
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(dstObj, fieldNameIdent)
  if isStringType(userType):
    return @[newAssignment(dstAccess, newCall(ident("cwireAllocStr"), srcAccess))]
  @[newAssignment(dstAccess, srcAccess)]

proc emitUnpackStmt(
    resultObj, srcObj, fieldNameIdent, userType: NimNode
): seq[NimNode] =
  ## Fill `resultObj.<field>` from `srcObj.<field>`: `$cstring` copies into
  ## Nim-managed memory, POD is a direct copy.
  let srcAccess = newDotExpr(srcObj, fieldNameIdent)
  let dstAccess = newDotExpr(resultObj, fieldNameIdent)
  if isStringType(userType):
    return @[newAssignment(dstAccess, newCall(ident("$"), srcAccess))]
  @[newAssignment(dstAccess, srcAccess)]

proc emitFreeStmt(dstObj, fieldNameIdent, userType: NimNode): seq[NimNode] =
  ## Release `dstObj.<field>`: free the cstring for strings, nothing for POD.
  let dstAccess = newDotExpr(dstObj, fieldNameIdent)
  if isStringType(userType):
    return @[newCall(ident("cwireFreeStr"), dstAccess)]
  @[]

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

proc ensureCWireFor(typeName: string, sink: NimNode) {.compileTime.} =
  ## Idempotent: if `typeName`'s cwire companion has not yet been emitted,
  ## append its TypeSection and conversion procs to `sink` and mark it emitted.
  if isCWireEmitted(typeName):
    return
  markCWireEmitted(typeName)
  let info = fieldInfoForType(typeName)
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
