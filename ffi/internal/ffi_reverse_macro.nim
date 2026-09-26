## `{.ffiReverse.}`: a call the library makes and the host answers.
##
## The proc is declared without a body, like an import: the host implements it.
## What the macro writes is the asking side — the arguments as one CBOR map, the
## wait, and the answer decoded into the declared return type.

import std/[macros, strutils]
import ../codegen/string_helpers

proc reverseArgsTypeName(procName: string): string =
  return snakeToPascalCase(camelToSnakeCase(procName)) & "HostCall"

macro ffiReverse*(prc: untyped): untyped =
  ## `proc hostFetch(url: string): Future[Result[string, string]] {.ffiReverse.}`
  if prc.kind notin {nnkProcDef, nnkFuncDef}:
    error("`.ffiReverse.` must be applied to a proc declaration")

  let body = prc[^1]
  if not (body.kind == nnkEmpty or (body.kind == nnkStmtList and body.len == 0)):
    error(
      "`.ffiReverse.` declares a call the host answers, so it takes no body; " &
        "remove the body of " & $prc[0]
    )

  let formalParams = prc[3]
  let retTypeNode = formalParams[0]
  if retTypeNode.kind != nnkBracketExpr or $retTypeNode[0] != "Future" or
      retTypeNode[1].kind != nnkBracketExpr or $retTypeNode[1][0] != "Result":
    error(
      "`.ffiReverse.` must return Future[Result[T, string]], got: " & retTypeNode.repr
    )
  let valueType = retTypeNode[1][1]

  var procNameNode = prc[0]
  if procNameNode.kind == nnkPostfix:
    procNameNode = procNameNode[1]
  let procNameStr = $procNameNode
  let wireName = camelToSnakeCase(procNameStr)

  # The arguments ride as one named map, the same shape a request uses, so the
  # host decodes one typed value instead of a positional list.
  let argsTypeName = ident(reverseArgsTypeName(procNameStr))
  var fields: seq[NimNode] = @[]
  var assigns: seq[NimNode] = @[]
  for i in 1 ..< formalParams.len:
    let paramName = formalParams[i][0]
    let paramType = formalParams[i][1]
    fields.add(
      newTree(nnkIdentDefs, postfix(paramName, "*"), paramType, newEmptyNode())
    )
    assigns.add(newTree(nnkExprColonExpr, paramName, paramName))
  if fields.len == 0:
    fields.add(
      newTree(
        nnkIdentDefs,
        postfix(ident("_placeholder"), "*"),
        ident("uint8"),
        newEmptyNode(),
      )
    )

  let argsType = newTree(nnkTypeSection).add(
      newTree(
        nnkTypeDef,
        postfix(argsTypeName, "*"),
        newEmptyNode(),
        newTree(
          nnkObjectTy, newEmptyNode(), newEmptyNode(), newTree(nnkRecList, fields)
        ),
      )
    )

  let argsCtor = newTree(nnkObjConstr, argsTypeName)
  for a in assigns:
    argsCtor.add(a)

  let wireNameLit = newLit(wireName)
  let callBody = quote:
    let outb = ffiCurrentOutbound()
    if outb.isNil():
      return err("a reverse call can only be made from an FFI handler")
    let argsCbor = cborEncode(`argsCtor`)
    let answer = await callHost(
      proc() {.gcsafe, raises: [].} =
        outb[].notifyOutbound(),
      outb[].reverse,
      nameId(`wireNameLit`),
      ffiCurrentClaim(),
      argsCbor,
      proc(): uint64 {.gcsafe, raises: [].} =
        outb[].nextSeq(),
    )
    if answer.isErr():
      return err(answer.error)
    let decoded = cborDecode(answer.value, `valueType`)
    if decoded.isErr():
      return err("the host's answer did not decode: " & decoded.error)
    return ok(decoded.value)

  var callProc = prc.copyNimTree()
  callProc[^1] = callBody
  # Only cancellation can escape: the answer, a timeout, a host that never
  # replies, all come back as the Result's error.
  callProc[4] = newTree(
    nnkPragma,
    newTree(
      nnkExprColonExpr,
      ident("async"),
      newTree(nnkTupleConstr, newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket, ident("CancelledError")))),
    ),
  )

  let stmts = newStmtList(argsType, callProc)
  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts
