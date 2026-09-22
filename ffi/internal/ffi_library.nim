import
  std/[macros, atomics, sysatomics, compilesettings], strformat, chronicles, chronos
import strutils
import ../codegen/meta

func nimMainPrefixOnCmdLine(cmdLine: string): tuple[found: bool, value: string] =
  ## Last `--nimMainPrefix:X` on the command line (style-insensitive match, `:`
  ## or `=`); absence isn't proof it was never set (config.nims may not surface).
  var found = false
  var value = ""
  for tok in cmdLine.splitWhitespace():
    let body = tok.strip(trailing = false, chars = {'-'})
    let sep = body.find({':', '='})
    if sep < 0:
      continue
    if body[0 ..< sep].toLowerAscii().replace("_", "") == "nimmainprefix":
      found = true
      value = body[sep + 1 .. ^1]
  (found, value)

proc validateNimMainPrefix(libraryName: string) {.compileTime.} =
  ## The init symbol is importc'd as `lib{libraryName}NimMain`, so the build must
  ## pass `--nimMainPrefix:lib{libraryName}`; a mismatch errors, absence only
  ## hints (config.nims may set it) and only under `--app:lib`.
  let expectedPrefix = "lib" & libraryName
  let (prefixFound, prefixValue) =
    nimMainPrefixOnCmdLine(querySetting(SingleValueSetting.commandLine))
  if prefixFound and prefixValue != expectedPrefix:
    error(
      "declareLibrary(\"" & libraryName &
        "\"): the Nim runtime init symbol is importc'd as " & expectedPrefix &
        "NimMain, so the build needs --nimMainPrefix:" & expectedPrefix &
        ", but the command line passes --nimMainPrefix:" & prefixValue &
        ". Change the flag to --nimMainPrefix:" & expectedPrefix &
        " (it must be \"lib\" followed by the declareLibrary name)."
    )
  elif not prefixFound and compileOption("app", "lib"):
    hint(
      "declareLibrary(\"" & libraryName & "\"): pass --nimMainPrefix:" & expectedPrefix &
        " so the Nim runtime init symbol " & expectedPrefix &
        "NimMain resolves; without it the build may fail with an undefined-symbol" &
        " link error (ignore this hint if the prefix is set in config.nims)."
    )

macro declareLibraryBase*(libraryName: static[string]): untyped =
  currentLibName = libraryName

  validateNimMainPrefix(libraryName)

  var res = newStmtList()

  # {.pragma: exported, exportc, cdecl, raises: [].}
  res.add nnkPragma.newTree(
    nnkExprColonExpr.newTree(ident"pragma", ident"exported"),
    ident"exportc",
    ident"cdecl",
    nnkExprColonExpr.newTree(ident"raises", nnkBracket.newTree()),
  )

  # {.pragma: callback, cdecl, raises: [], gcsafe.}
  res.add nnkPragma.newTree(
    nnkExprColonExpr.newTree(ident"pragma", ident"callback"),
    ident"cdecl",
    nnkExprColonExpr.newTree(ident"raises", nnkBracket.newTree()),
    ident"gcsafe",
  )

  # {.passc: "-fPIC".}
  res.add nnkPragma.newTree(nnkExprColonExpr.newTree(ident"passc", newLit("-fPIC")))

  # soname / install_name only apply to a shared library and break an executable link (fatally on macOS), so emit them only under `--app:lib`.
  if compileOption("app", "lib"):
    when defined(linux):
      let soName = fmt"-Wl,-soname,lib{libraryName}.so"
      res.add(
        newNimNode(nnkPragma).add(
          nnkExprColonExpr.newTree(ident"passl", newStrLitNode(soName))
        )
      )
    elif defined(macosx):
      let installName = fmt"-install_name @rpath/lib{libraryName}.dylib"
      res.add(
        newNimNode(nnkPragma).add(
          nnkExprColonExpr.newTree(ident"passl", newStrLitNode(installName))
        )
      )
  # proc lib{libraryName}NimMain() {.importc.}
  let libNimMainName = ident(fmt"lib{libraryName}NimMain")
  let importcPragma = nnkPragma.newTree(ident"importc")
  let procDef = newProc(
    name = libNimMainName,
    params = @[ident"void"],
    pragmas = importcPragma,
    body = newEmptyNode(),
  )
  res.add(procDef)

  # initState: 0=not started, 1=in progress, 2=done. Atomic (not a bool) so a racing caller can't skip past the gate mid-init (else Windows WSAStartup fails).
  let atomicType = nnkBracketExpr.newTree(ident("Atomic"), ident("int"))
  let varStmt = nnkVarSection.newTree(
    nnkIdentDefs.newTree(ident("initState"), atomicType, newEmptyNode())
  )
  res.add(varStmt)

  let procName = ident("initializeLibrary")
  let nimMainName = ident("lib" & libraryName & "NimMain")

  let initializeLibraryProc = quote:
    proc `procName`*() {.exported.} =
      ## Calls `<prefix>NimMain` exactly once to init the Nim runtime. Concurrent
      ## callers must block until it returns (its chronos globalInit runs
      ## WSAStartup on Windows; racing past yields "WSAStartup failed" later).
      var expected: int = 0
      if initState.compareExchange(expected, 1):
        `nimMainName`()
        initState.store(2)
      else:
        while initState.load() != 2:
          cpuRelax()
      when declared(setupForeignThreadGc):
        setupForeignThreadGc()
      when declared(nimGC_setStackBottom):
        var locals {.volatile, noinit.}: pointer
        locals = addr(locals)
        nimGC_setStackBottom(locals)

  res.add(initializeLibraryProc)

  return res

macro declareLibrary*(libraryName: static[string], libType: untyped): untyped =
  ## Declares a library and emits its `FFIContext` listener ABI (add/remove).
  currentLibType = $libType # so handle-receiver `.ffi.` procs can resolve the pool
  libraryDeclared = true

  var stmts = newStmtList()

  stmts.add(newCall(ident("declareLibraryBase"), newStrLitNode(libraryName)))

  # The pool the generated wrappers validate against.
  let poolIdent = ident($libType & "FFIPool")
  stmts.add quote do:
    when not declared(`poolIdent`):
      var `poolIdent`*: FFIContextPool[`libType`]

  let cdeclExportPragma = newTree(
    nnkPragma,
    ident("dynlib"),
    ident("exportc"),
    ident("cdecl"),
    newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
  )

  # `ctxIdent` is substituted so the bodies below see it (`quote` gensyms).
  let ctxIdent = ident("ctx")

  when defined(ffiPollMode):
    # {libraryName}_poll. No `initializeLibrary`: a token that resolves proves the
    # runtime is up, and poll makes no Nim allocation, so the thread needs no GC setup.
    let pollName = libraryName & "_poll"
    let pollBody = quote:
      let `ctxIdent` = `poolIdent`.resolveCtx(ctxToken)
      if `ctxIdent`.isNil():
        if not msg.isNil():
          msg[] = nil
        return RET_INVALID_CTX
      return pollContext(`ctxIdent`, ctxToken.tokenGeneration(), int(timeoutMs), msg)

    stmts.add(
      newProc(
        name = ident(pollName),
        params = @[
          ident("cint"),
          newIdentDefs(ident("ctxToken"), ident("FFICtxToken")),
          newIdentDefs(ident("timeoutMs"), ident("int32")),
          newIdentDefs(
            ident("msg"), newTree(nnkPtrTy, newTree(nnkPtrTy, ident("NimFfiMsg")))
          ),
        ],
        body = pollBody,
        pragmas = cdeclExportPragma,
      )
    )

    let pollFdName = libraryName & "_poll_fd"
    let pollFdBody = quote:
      return pollContextHandle(`poolIdent`.resolveCtx(ctxToken))

    stmts.add(
      newProc(
        name = ident(pollFdName),
        params = @[ident("int"), newIdentDefs(ident("ctxToken"), ident("FFICtxToken"))],
        body = pollFdBody,
        pragmas = cdeclExportPragma,
      )
    )

  when defined(ffiPollMode):
    # {libraryName}_reverse_reply: the host's answer to a NIMFFI_MSG_REVERSE_CALL.
    let reverseReplyName = libraryName & "_reverse_reply"
    let reverseReplyBody = quote:
      let `ctxIdent` = `poolIdent`.resolveCtx(ctxToken)
      if `ctxIdent`.isNil():
        return RET_INVALID_CTX
      if not `ctxIdent`[].outbound.reverse.pushReply(
        callId, retCode, cast[pointer](payload), int(payloadLen)
      ):
        return RET_ERR
      # The FFI thread matches the id; an answer it does not know is dropped there.
      `ctxIdent`.wakeFFIThread()
      return RET_OK

    stmts.add(
      newProc(
        name = ident(reverseReplyName),
        params = @[
          ident("cint"),
          newIdentDefs(ident("ctxToken"), ident("FFICtxToken")),
          newIdentDefs(ident("callId"), ident("uint64")),
          newIdentDefs(ident("retCode"), ident("cint")),
          newIdentDefs(ident("payload"), nnkPtrTy.newTree(ident("byte"))),
          newIdentDefs(ident("payloadLen"), ident("csize_t")),
        ],
        body = reverseReplyBody,
        pragmas = cdeclExportPragma,
      )
    )

    # {libraryName}_last_error: an export returns a code, this gives the words.
    let lastErrorName = libraryName & "_last_error"
    let lastErrorBody = quote:
      return lastError()

    stmts.add(
      newProc(
        name = ident(lastErrorName),
        params = @[ident("cstring")],
        body = lastErrorBody,
        pragmas = cdeclExportPragma,
      )
    )

    # {libraryName}_static_ctx: the replies of `{.ffiStatic.}` requests arrive on
    # the library's own context, so the host needs its token to poll for them.
    let staticCtxName = libraryName & "_static_ctx"
    let staticCtxBody = quote:
      when declared(initializeLibrary):
        initializeLibrary()
      let `ctxIdent` = `poolIdent`.staticFFIContext().valueOr:
        setLastError("static context: " & error)
        return FFICtxToken(nil)
      return `ctxIdent`.ffiToken()

    stmts.add(
      newProc(
        name = ident(staticCtxName),
        params = @[ident("FFICtxToken")],
        body = staticCtxBody,
        pragmas = cdeclExportPragma,
      )
    )

  # A polling host takes its events out of the message queue, so a library
  # built for it has no listener registry to add to.
  when not defined(ffiPollMode):
    # {libraryName}_add_event_listener
    let addName = libraryName & "_add_event_listener"
    let addErr = "error: invalid context in " & addName
    let addBody = quote:
      # This code runs on the foreign caller thread. That thread can differ from
      # the thread of an earlier entry point. If the GC of the thread is not
      # ready, the first Nim allocation ($eventName, the registry Table and seq)
      # faults. Therefore initialize the GC here.
      when declared(initializeLibrary):
        initializeLibrary()
      var ret: uint64 = 0
      let `ctxIdent` = `poolIdent`.resolveCtx(ctxToken)
      if `ctxIdent`.isNil():
        echo `addErr`
        return ret
      let evtName =
        if eventName.isNil():
          ""
        else:
          $eventName
      ret = addEventListener(`ctxIdent`[].eventRegistry, evtName, callback, userData)
      return ret

    stmts.add(
      newProc(
        name = ident(addName),
        params = @[
          ident("uint64"),
          newIdentDefs(ident("ctxToken"), ident("FFICtxToken")),
          newIdentDefs(ident("eventName"), ident("cstring")),
          newIdentDefs(ident("callback"), ident("FFICallBack")),
          newIdentDefs(ident("userData"), ident("pointer")),
        ],
        body = addBody,
        pragmas = cdeclExportPragma,
      )
    )

    # Param is `listenerId`, not `id`: `id` collides with chronos's `futures.id` template under quote injection and the captured symbol wins.
    let removeName = libraryName & "_remove_event_listener"
    let removeErr = "error: invalid context in " & removeName
    let removeBody = quote:
      when declared(initializeLibrary):
        initializeLibrary()
      var ret: cint = 1
      let `ctxIdent` = `poolIdent`.resolveCtx(ctxToken)
      if `ctxIdent`.isNil():
        echo `removeErr`
        return ret
      if removeEventListener(`ctxIdent`[].eventRegistry, listenerId):
        ret = 0
      return ret

    stmts.add(
      newProc(
        name = ident(removeName),
        params = @[
          ident("cint"),
          newIdentDefs(ident("ctxToken"), ident("FFICtxToken")),
          newIdentDefs(ident("listenerId"), ident("uint64")),
        ],
        body = removeBody,
        pragmas = cdeclExportPragma,
      )
    )

  # {libraryName}_shutdown
  let shutdownName = libraryName & "_shutdown"
  let shutdownBody = quote:
    # A host can call shutdown first of all; the Nim runtime must be up before the pool is read.
    when declared(initializeLibrary):
      initializeLibrary()
    var ret: cint = 0
    if `poolIdent`.shutdownFFIContextPool().isErr():
      ret = 1
    return ret

  stmts.add(
    newProc(
      name = ident(shutdownName),
      params = @[ident("cint")],
      body = shutdownBody,
      pragmas = cdeclExportPragma,
    )
  )

  return stmts
