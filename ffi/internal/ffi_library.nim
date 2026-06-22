import std/[macros, atomics, sysatomics], strformat, chronicles, chronos
import ../codegen/meta

macro declareLibraryBase*(libraryName: static[string]): untyped =
  # Record the library name for binding generation
  currentLibName = libraryName

  var res = newStmtList()

  ## Generate {.pragma: exported, exportc, cdecl, raises: [].}
  res.add nnkPragma.newTree(
    nnkExprColonExpr.newTree(ident"pragma", ident"exported"),
    ident"exportc",
    ident"cdecl",
    nnkExprColonExpr.newTree(ident"raises", nnkBracket.newTree()),
  )

  ## Generate {.pragma: callback, cdecl, raises: [], gcsafe.}
  res.add nnkPragma.newTree(
    nnkExprColonExpr.newTree(ident"pragma", ident"callback"),
    ident"cdecl",
    nnkExprColonExpr.newTree(ident"raises", nnkBracket.newTree()),
    ident"gcsafe",
  )

  ## Generate {.passc: "-fPIC".}
  res.add nnkPragma.newTree(nnkExprColonExpr.newTree(ident"passc", newLit("-fPIC")))

  # soname / install_name only apply to a shared library and break an executable
  # link (fatally on macOS), so emit them only under `--app:lib`.
  if compileOption("app", "lib"):
    when defined(linux):
      ## Generates {.passl: "-Wl,-soname,libwaku.so".} (considering libraryName=="waku", for example)
      let soName = fmt"-Wl,-soname,lib{libraryName}.so"
      res.add(
        newNimNode(nnkPragma).add(
          nnkExprColonExpr.newTree(ident"passl", newStrLitNode(soName))
        )
      )
    elif defined(macosx):
      ## Generates {.passl: "-install_name @rpath/libwaku.dylib".}
      let installName = fmt"-install_name @rpath/lib{libraryName}.dylib"
      res.add(
        newNimNode(nnkPragma).add(
          nnkExprColonExpr.newTree(ident"passl", newStrLitNode(installName))
        )
      )
  ## proc lib{libraryName}NimMain() {.importc.}
  let libNimMainName = ident(fmt"lib{libraryName}NimMain")
  let importcPragma = nnkPragma.newTree(ident"importc")
  let procDef = newProc(
    name = libNimMainName,
    params = @[ident"void"],
    pragmas = importcPragma,
    body = newEmptyNode(),
  )
  res.add(procDef)

  # Create: var initState: Atomic[int]
  #   0 = not started, 1 = in progress (some thread is running nimMainName),
  #   2 = done. A boolean flag flipped before nimMainName runs would let a
  #   second concurrent caller skip past the gate while module init was
  #   still in flight — on Windows that surfaces as "WSAStartup failed"
  #   from chronos's later async dispatcher init on a watchdog thread.
  let atomicType = nnkBracketExpr.newTree(ident("Atomic"), ident("int"))
  let varStmt = nnkVarSection.newTree(
    nnkIdentDefs.newTree(ident("initState"), atomicType, newEmptyNode())
  )
  res.add(varStmt)

  ## Android chronicles redirection
  let chroniclesBlock = quote:
    when defined(android) and compiles(defaultChroniclesStream.outputs[0].writer):
      defaultChroniclesStream.outputs[0].writer = proc(
          logLevel: LogLevel, msg: LogOutputStr
      ) {.raises: [].} =
        echo logLevel, msg
      result.add(chroniclesBlock)

  let procName = ident("initializeLibrary")
  let nimMainName = ident("lib" & libraryName & "NimMain")

  let initializeLibraryProc = quote:
    proc `procName`*() {.exported.} =
      ## Every Nim library needs to call `<yourprefix>NimMain` once exactly,
      ## to initialize the Nim runtime.
      ## Being `<yourprefix>` the value given in the optional
      ## compilation flag --nimMainPrefix:yourprefix.
      ##
      ## Concurrent callers must NOT proceed past nimMainName until it has
      ## fully returned: chronos's module-level globalInit (which calls
      ## WSAStartup on Windows) runs as part of nimMainName, and a thread
      ## that races past would later see "WSAStartup failed" when its
      ## watchdog spins up a chronos dispatcher.
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

macro declareLibrary*(
    libraryName: static[string],
    libType: untyped,
    defaultABIFormat: static[string] = "cbor",
): untyped =
  ## Declares a library with the given name and emits the C-exported event
  ## ABI on its `FFIContext`:
  ##
  ## - `{libraryName}_add_event_listener(ctx, event_name, cb, ud) -> uint64`
  ##   — registers `cb` for `event_name` and returns its stable id. `cb`
  ##   only receives events dispatched under `event_name`; subscribe to
  ##   each event separately.
  ## - `{libraryName}_remove_event_listener(ctx, id) -> cint` — returns 0 on
  ##   success, non-zero if no listener with that id exists.
  ##
  ## `libType` is the Nim type of the main library object, used to type
  ## the `ctx: ptr FFIContext[libType]` parameter. See
  ## `examples/timer/timer.nim` for a working call site.
  ##
  ## `defaultABIFormat` (`"cbor"` default, or `"c"`) is the wire format every
  ## annotation inherits unless it overrides with an `"abi = ..."` spec.
  currentLibType = $libType # so handle-receiver `.ffi.` procs can resolve the pool

  let (abiOk, abiFmt) = parseABIFormatName(defaultABIFormat)
  if not abiOk:
    error(
      "declareLibrary: unknown defaultABIFormat '" & defaultABIFormat &
        "'; valid values are \"c\" and \"cbor\""
    )
  currentDefaultABIFormat = abiFmt
  libraryDeclared = true

  var stmts = newStmtList()

  # Emit the base bootstrap (pragmas, linker flags, NimMain, initializeLibrary)
  stmts.add(newCall(ident("declareLibraryBase"), newStrLitNode(libraryName)))

  # The pool the generated wrappers validate against; ffiCtor/ffiDtor guard alike.
  let poolIdent = ident($libType & "FFIPool")
  stmts.add quote do:
    when not declared(`poolIdent`):
      var `poolIdent`*: FFIContextPool[`libType`]

  let ctxType = nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libType))
  let cdeclExportPragma = newTree(
    nnkPragma,
    ident("dynlib"),
    ident("exportc"),
    ident("cdecl"),
    newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
  )

  # {libraryName}_add_event_listener
  let addName = libraryName & "_add_event_listener"
  let addErr = "error: invalid context in " & addName
  let addBody = quote:
    var ret: uint64 = 0
    if isNil(ctx):
      echo `addErr`
      return ret
    let evtName =
      if eventName.isNil():
        ""
      else:
        $eventName
    ret = addEventListener(ctx[].eventRegistry, evtName, callback, userData)
    return ret

  stmts.add(
    newProc(
      name = ident(addName),
      params = @[
        ident("uint64"),
        newIdentDefs(ident("ctx"), ctxType),
        newIdentDefs(ident("eventName"), ident("cstring")),
        newIdentDefs(ident("callback"), ident("FFICallBack")),
        newIdentDefs(ident("userData"), ident("pointer")),
      ],
      body = addBody,
      pragmas = cdeclExportPragma,
    )
  )

  # --- {libraryName}_remove_event_listener --------------------------------
  # Param is `listenerId`, not `id` — `id` collides with chronos's
  # `futures.id` template under quote injection rules and the captured
  # symbol wins over the injected one.
  let removeName = libraryName & "_remove_event_listener"
  let removeErr = "error: invalid context in " & removeName
  let removeBody = quote:
    var ret: cint = 1
    if isNil(ctx):
      echo `removeErr`
      return ret
    if removeEventListener(ctx[].eventRegistry, listenerId):
      ret = 0
    return ret

  stmts.add(
    newProc(
      name = ident(removeName),
      params = @[
        ident("cint"),
        newIdentDefs(ident("ctx"), ctxType),
        newIdentDefs(ident("listenerId"), ident("uint64")),
      ],
      body = removeBody,
      pragmas = cdeclExportPragma,
    )
  )

  return stmts
