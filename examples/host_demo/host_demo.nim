## Minimal example exercising a {.ffiHost.} host callback end-to-end from Go.
##
## `fetchToken` is implemented by the *host* (the Go app); `useToken` is a normal
## {.ffi.} method the host calls, which in turn asks the host for a token via
## `fetchToken` and awaits it. This proves the inverted call direction across the
## real FFI boundary with the generated Go wrapper.

import ffi, chronos, results

type Demo = object

declareLibrary("host_demo", Demo)

# Ctor first: the {.ffiCtor.} macro declares the per-lib FFI pool that the
# {.ffi.} method below references.
proc demoCreate(): Future[Result[Demo, string]] {.ffiCtor.} =
  return ok(Demo())

proc demoDestroy(d: Demo) {.ffiDtor.} =
  discard

# Host-implemented: the Go app registers this with SetFetchToken.
proc fetchToken(key: string): Future[Result[string, string]] {.ffiHost.}

# A {.ffi.} method the host calls; it asks the host for a token and wraps it.
proc useToken(d: Demo, key: string): Future[Result[string, string]] {.ffi.} =
  let tok = (await fetchToken(key)).valueOr:
    return err("host error: " & error)
  return ok("token[" & tok & "]")

genBindings()
