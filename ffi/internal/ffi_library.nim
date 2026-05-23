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
      block waitForInit:
        while true:
          var expected: int = 0
          if initState.compareExchange(expected, 1):
            `nimMainName`()
            initState.store(2)
            break waitForInit
          if initState.load() == 2:
            break waitForInit
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
  ## Declares a library with the given name and automatically generates
  ## `{libraryName}_set_event_callback`, a C-exported function that stores the
  ## caller's event callback on the FFIContext.
  ##
  ## `libType` is the Nim type of the main library object (e.g. `Waku`). It is used
  ## to type the `ctx: ptr FFIContext[libType]` parameter of the generated
  ## `{libraryName}_set_event_callback` proc.
  var stmts = newStmtList()

  # Emit the base bootstrap (pragmas, linker flags, NimMain, initializeLibrary)
  stmts.add(newCall(ident("declareLibraryBase"), newStrLitNode(libraryName)))

  let funcName = libraryName & "_set_event_callback"
  let funcIdent = ident(funcName)
  let errorMsg = "error: invalid context in " & funcName

  let ctxType = nnkPtrTy.newTree(nnkBracketExpr.newTree(ident("FFIContext"), libType))

  let procBody = quote:
    if isNil(ctx):
      echo `errorMsg`
      return
    setCallback(ctx[].callbackState, cast[pointer](callback), userData)

  let procNode = newProc(
    name = funcIdent,
    params = @[
      newEmptyNode(),
      newIdentDefs(ident("ctx"), ctxType),
      newIdentDefs(ident("callback"), ident("FFICallBack")),
      newIdentDefs(ident("userData"), ident("pointer")),
    ],
    body = procBody,
    pragmas = newTree(
      nnkPragma,
      ident("dynlib"),
      ident("exportc"),
      ident("cdecl"),
      newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
    ),
  )

  stmts.add(procNode)
  return stmts
