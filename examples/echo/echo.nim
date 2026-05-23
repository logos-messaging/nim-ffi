## Minimal second example library used by the C++ CrossLibrary e2e test.
## Exists alongside `examples/timer` so a single test binary can load
## libecho + libmy_timer at the same time and prove no symbol clash and
## no shared global state between two independent nim-ffi libraries.

import ffi, chronos

type Echo = object
  prefix: string

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
  var upper = newStringOfCap(req.text.len)
  for c in req.text:
    upper.add(if c in {'a' .. 'z'}: chr(ord(c) - 32) else: c)
  return ok(ShoutResponse(shouted: e.prefix & ": " & upper, prefix: e.prefix))

proc echoVersion*(e: Echo): Future[Result[string, string]] {.ffi.} =
  return ok("nim-echo v0.1.0")

proc echo_destroy*(e: Echo) {.ffiDtor.} =
  discard

genBindings()
