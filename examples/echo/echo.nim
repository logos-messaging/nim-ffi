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

# Constants never cross the wire, so {.ffiConst.} lands in the abi = c header too.
const MaxShoutLen* {.ffiConst.} = 512

type EchoConfig {.ffi.} = object
  prefix: string

type ShoutRequest {.ffi.} = object
  text: string

type ShoutResponse {.ffi.} = object
  shouted: string
  prefix: string

proc echoCreate*(config: EchoConfig): Future[Result[Echo, string]] {.ffiCtor.} =
  ## Creates an echo context that prefixes every reply with `config.prefix`.
  await sleepAsync(1.milliseconds)
  return ok(Echo(prefix: config.prefix))

proc echoShout*(
    e: Echo, req: ShoutRequest
): Future[Result[ShoutResponse, string]] {.ffi.} =
  ## Upper-cases `req.text` and returns it behind the context's prefix.
  if req.text.len > MaxShoutLen:
    return err("text must not exceed " & $MaxShoutLen & " bytes")
  await sleepAsync(1.milliseconds)
  let upper = req.text.toUpperAscii
  return ok(ShoutResponse(shouted: e.prefix & ": " & upper, prefix: e.prefix))

proc echoVersion*(e: Echo): Future[Result[string, string]] {.ffi.} =
  ## Returns the library's version string.
  return ok("nim-echo v0.1.0")

proc echo_destroy*(e: Echo) {.ffiDtor.} =
  ## Releases the echo context.
  discard

genBindings()
