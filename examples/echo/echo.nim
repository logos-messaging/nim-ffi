## Second nim-ffi example library — loaded alongside examples/timer in the
## C++ CrossLibrary e2e test to prove two libs coexist in one process.

import ffi, chronos, strutils

type Echo = object
  prefix: string

# `-d:ffiEchoAbiC` builds the `abi = c` variant; default is the CBOR ABI.
when defined(ffiEchoAbiC):
  declareLibrary("echo", Echo, defaultABIFormat = "c")
else:
  declareLibrary("echo", Echo)

type EchoConfig {.ffi.} = object
  prefix: string

type ShoutRequest {.ffi.} = object
  text: string

type ShoutResponse {.ffi.} = object
  shouted: string
  prefix: string

proc echoCreate*(config: EchoConfig): Future[Result[Echo, string]] {.ffiCtor.} =
  await sleepAsync(1.milliseconds)
  return ok(Echo(prefix: config.prefix))

proc echoShout*(
    e: Echo, req: ShoutRequest
): Future[Result[ShoutResponse, string]] {.ffi.} =
  await sleepAsync(1.milliseconds)
  let upper = req.text.toUpperAscii
  return ok(ShoutResponse(shouted: e.prefix & ": " & upper, prefix: e.prefix))

proc echoVersion*(e: Echo): Future[Result[string, string]] {.ffi.} =
  return ok("nim-echo v0.1.0")

proc echo_destroy*(e: Echo) {.ffiDtor.} =
  discard

genBindings()
