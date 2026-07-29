## Simple synchronous C export for a nim-ffi library.
##
## `{.ffi.}` and `{.ffiCtor.}` give the async path. That path uses a context
## handle and encodes the data with CBOR. It fits a library that keeps state
## across many calls. `{.ffiExport.}` covers the other common case: a few simple
## lifecycle entry points. The host loads them with `dlopen` and `dlsym`, then
## calls them synchronously. There is no context, no callback and no CBOR. The
## return value of the function crosses the ABI directly.
##
## Write native Nim types. `ffiExport` maps them to the C ABI:
##   int / bool  -> C  int
##   uint64      -> C  unsigned long long
##   string      -> C  const char*   (stays alive in shared memory until the next call)
##   (no return) -> C  void
## `ffiExport` also injects the `initializeLibrary()` call of the library. The Nim
## runtime therefore starts on the first call, and the host never calls NimMain.
##
##   declareLibraryBase("myLib")                       # emits initializeLibrary()
##   proc my_start(): int {.ffiExport.} = 0            # -> int my_start(void)
##   proc my_alive(): uint64 {.ffiExport.} = beats     # -> unsigned long long my_alive(void)
##   proc my_error(): string {.ffiExport.} = lastErr   # -> const char* my_error(void)
##
## Build the shared library with `--noMain --nimMainPrefix:libmyLib`. A proc with
## `{.ffiExport.}` takes no arguments. For a call with arguments, use `{.ffi.}`.

import std/macros
import ./ffi_route

proc cReturnType(t: NimNode): NimNode =
  ## Maps the native Nim return type to the C ABI type that crosses the boundary.
  if t.kind == nnkEmpty:
    return t # void
  if t.kind == nnkIdent:
    case $t
    of "int", "int32", "bool":
      return ident("cint")
    of "uint", "uint64":
      return ident("culonglong")
    of "string":
      return ident("cstring")
    else:
      discard
  return t # already a C-compatible type

proc buildFFIExportProc*(prc: NimNode): NimNode {.compileTime.} =
  ## Emits the synchronous C export. `{.ffi.}` and `{.ffiExport.}` share it.
  prc.expectKind({nnkProcDef, nnkFuncDef})
  let exportName = $procIdent(prc)
  let params = prc.params
  let nativeRet = params[0]
  let cRet = cReturnType(nativeRet)

  # The user body becomes a private impl proc. The exported wrapper converts the
  # result.
  let implName = genSym(nskProc, exportName & "Impl")
  var impl = copyNimTree(prc)
  impl[0] = implName # rename
  impl[4] = newEmptyNode() # remove the pragmas: this proc stays internal

  let wrapName = ident(exportName)
  let boot = quote:
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
        if `buf` != nil:
          deallocShared(`buf`)
        `buf` = allocShared(s.len + 1)
        if s.len > 0:
          copyMem(`buf`, unsafeAddr s[0], s.len)
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

macro ffiExport*(prc: untyped): untyped =
  ## Marks a proc that takes no arguments as a simple synchronous C export. The
  ## macro maps the native Nim return type to the C ABI and starts the Nim
  ## runtime. `{.ffi.}` reaches the same path from the shape alone. See the
  ## module doc.
  prc.expectKind({nnkProcDef, nnkFuncDef})
  assertFFIPath(prc, fpExport)
  return buildFFIExportProc(prc)
