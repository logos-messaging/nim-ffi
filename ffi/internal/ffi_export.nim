## Simple synchronous C export for a nim-ffi library.
##
## `{.ffi.}` / `{.ffiCtor.}` are the async, context-handle, CBOR-marshaled path —
## the right tool for stateful, multi-call libraries. `{.ffiExport.}` covers the
## other common case: a handful of DEAD-SIMPLE lifecycle/health entry points a host
## loads with plain `dlopen` + `dlsym` and calls synchronously — no context, no
## callback, no CBOR. The function's own return value crosses the ABI directly.
##
## You write NATIVE Nim types; `ffiExport` bridges to the C ABI for you:
##   int / bool  -> C  int
##   uint64      -> C  unsigned long long
##   string      -> C  const char*   (kept alive in shared memory until the next call)
##   (no return) -> C  void
## and it injects the library's `initializeLibrary()` bootstrap so the Nim runtime
## is up on first call — the host never invokes NimMain itself.
##
##   declareLibraryBase("myLib")                       # emits initializeLibrary()
##   proc my_start(): int {.ffiExport.} = 0            # -> int my_start(void)
##   proc my_alive(): uint64 {.ffiExport.} = beats     # -> unsigned long long my_alive(void)
##   proc my_error(): string {.ffiExport.} = lastErr   # -> const char* my_error(void)
##
## Build the shared library with `--noMain --nimMainPrefix:libmyLib`. Arguments are
## not supported (these are no-arg lifecycle calls); use `{.ffi.}` for calls that
## take arguments.

import std/macros

proc cReturnType(t: NimNode): NimNode =
  ## Native Nim return type -> the C-ABI type that actually crosses the boundary.
  if t.kind == nnkEmpty:
    return t                                   # void
  if t.kind == nnkIdent:
    case $t
    of "int", "int32", "bool": return ident("cint")
    of "uint", "uint64": return ident("culonglong")
    of "string": return ident("cstring")
    else: discard
  return t                                     # already a C-compatible type

macro ffiExport*(prc: untyped): untyped =
  ## Mark a no-argument proc as a simple synchronous C export (see module doc):
  ## native Nim return type, bridged to the C ABI, with the runtime bootstrapped.
  prc.expectKind({nnkProcDef, nnkFuncDef})
  let nameNode = if prc.name.kind == nnkPostfix: prc.name[1] else: prc.name
  let exportName = $nameNode
  let params = prc.params
  if params.len > 1:
    error("ffiExport supports no-argument procs; use {.ffi.} for calls with arguments")

  let nativeRet = params[0]
  let cRet = cReturnType(nativeRet)

  # The user's body becomes a private impl proc; the exported wrapper converts.
  let implName = genSym(nskProc, exportName & "Impl")
  var impl = copyNimTree(prc)
  impl[0] = implName            # rename
  impl[4] = newEmptyNode()      # drop pragmas (internal, not exported)

  let wrapName = ident(exportName)
  let boot = quote do:
    when declared(initializeLibrary):
      initializeLibrary()

  var res = newStmtList(impl)

  if nativeRet.kind == nnkIdent and $nativeRet == "string":
    # string -> const char*: keep the bytes alive in shared memory across the call.
    let buf = genSym(nskVar, exportName & "Buf")
    res.add quote do:
      var `buf` {.global.}: pointer = nil
      proc `wrapName`(): cstring {.exportc: `exportName`, cdecl, dynlib.} =
        `boot`
        let s = `implName`()
        if `buf` != nil: deallocShared(`buf`)
        `buf` = allocShared(s.len + 1)
        if s.len > 0: copyMem(`buf`, unsafeAddr s[0], s.len)
        cast[ptr char](cast[uint](`buf`) + uint(s.len))[] = '\0'
        return cast[cstring](`buf`)
  elif nativeRet.kind == nnkEmpty:
    res.add quote do:
      proc `wrapName`() {.exportc: `exportName`, cdecl, dynlib.} =
        `boot`
        `implName`()
  else:
    # scalar: convert the native result to the C return type (cint / culonglong / …).
    res.add quote do:
      proc `wrapName`(): `cRet` {.exportc: `exportName`, cdecl, dynlib.} =
        `boot`
        return `cRet`(`implName`())

  return res
