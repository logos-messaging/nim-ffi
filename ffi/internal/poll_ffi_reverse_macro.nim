## Poll-mode `{.ffiReverse.}`: a call the library makes and the host answers.
##
## The proc is declared without a body, like an import: the host implements it.
## What the macro writes is the asking side — the arguments as one CBOR map, the
## wait, and the answer decoded into the declared return type.

import std/[macros, strutils]
import ../codegen/string_helpers
import ../ffi_msg

proc reverseArgsTypeName(procName: string): string =
  return snakeToPascalCase(camelToSnakeCase(procName)) & "HostCall"

var pollReverseWireNames {.compileTime.}: seq[string]

proc buildPollFFIReverseProc*(
    prc: NimNode, wireName: string, timeoutNode: NimNode
): NimNode {.compileTime.} =
  ## The `{.ffiReverse.}` expansion of a poll-mode build: the host answers through
  ## `<lib>_reverse_reply`, so there is no `set_impl`.
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
  if wireName in pollReverseWireNames:
    error(
      "`.ffiReverse.` proc " & procNameStr & ": wire name '" & wireName &
        "' is already used by another reverse proc; the host tells them apart by it"
    )
  pollReverseWireNames.add(wireName)

  # The arguments ride as one named map, the same shape a request uses, so the
  # host decodes one typed value instead of a positional list.
  let argsTypeName = ident(reverseArgsTypeName(procNameStr))
  var fields: seq[NimNode] = @[]
  var assigns: seq[NimNode] = @[]
  for i in 1 ..< formalParams.len:
    let group = formalParams[i]
    # A grouped `a, b: T` is one entry holding every name, then the type and default.
    for j in 0 ..< group.len - 2:
      let paramName = group[j]
      fields.add(
        newTree(nnkIdentDefs, postfix(paramName, "*"), group[^2], newEmptyNode())
      )
      assigns.add(newTree(nnkExprColonExpr, paramName, paramName))
  let stmts = newStmtList()
  var argsExpr: NimNode
  if fields.len == 0:
    # An empty CBOR map: the args stay valid CBOR with nothing to decode.
    argsExpr = quote:
      @[0xa0'u8]
  else:
    stmts.add(
      newTree(nnkTypeSection).add(
        newTree(
          nnkTypeDef,
          postfix(argsTypeName, "*"),
          newEmptyNode(),
          newTree(
            nnkObjectTy, newEmptyNode(), newEmptyNode(), newTree(nnkRecList, fields)
          ),
        )
      )
    )
    let argsCtor = newTree(nnkObjConstr, argsTypeName)
    for a in assigns:
      argsCtor.add(a)
    argsExpr = quote:
      cborEncode(`argsCtor`)

  # Hashed here, once, not on every call.
  let wireNameIdLit = newLit(nameId(wireName))
  let answer = ident("hostAnswer")
  let callBody = newStmtList()
  callBody.add quote do:
    let outb = ffiCurrentOutbound()
    if outb.isNil():
      return err("a reverse call can only be made from an FFI handler")
    let argsCbor = `argsExpr`
    let `answer` = await callHost(
      proc() {.gcsafe, raises: [].} =
        outb[].notifyOutbound(),
      outb[].reverse,
      `wireNameIdLit`,
      argsCbor,
      proc(): uint64 {.gcsafe, raises: [].} =
        outb[].nextSeq(),
      `timeoutNode`,
    )
    if `answer`.isErr():
      return err(`answer`.error)

  if valueType.kind == nnkIdent and $valueType == "void":
    callBody.add quote do:
      return ok()
  else:
    callBody.add quote do:
      let decoded = cborDecode(`answer`.value, `valueType`)
      if decoded.isErr():
        return err("the host's answer did not decode: " & decoded.error)
      return ok(decoded.value)

  var callProc = prc.copyNimTree()
  callProc[^1] = callBody
  var pragmas = newTree(nnkPragma)
  if prc[4].kind == nnkPragma:
    for p in prc[4]:
      pragmas.add(p)
  pragmas.add(ident("async"))
  callProc[4] = pragmas

  stmts.add(callProc)
  when defined(ffiDumpMacros):
    echo stmts.repr
  return stmts
