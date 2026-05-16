## A second, independent Nim-built library used by the cross-library e2e
## test. It exists to prove that two unrelated nim-ffi libraries can be
## linked into the same process and exchange strings purely through the
## generated pure-C ABIs (no shared Nim runtime knowledge).
##
## Surface mirrors timer's at a smaller scale:
##   echoer_create(EchoerConfig)            -> ctx
##   echoer_shout(ctx, ShoutRequest)        -> ShoutResponse
##   echoer_destroy(ctx)

import ffi, chronos

type Echoer = object
  prefix: string

declareLibrary("echoer", Echoer)

type EchoerConfig {.ffi.} = object
  prefix: string

type ShoutRequest {.ffi.} = object
  message: string
  exclamations: int

type ShoutResponse {.ffi.} = object
  shouted: string
  prefixUsed: string

proc echoer_create*(config: EchoerConfig): Future[Result[Echoer, string]] {.ffiCtor.} =
  return ok(Echoer(prefix: config.prefix))

proc echoer_shout*(
    e: Echoer, req: ShoutRequest
): Future[Result[ShoutResponse, string]] {.ffi.} =
  var bangs = ""
  for _ in 0 ..< max(req.exclamations, 0):
    bangs.add('!')
  let shouted = e.prefix & ": " & req.message & bangs
  return ok(ShoutResponse(shouted: shouted, prefixUsed: e.prefix))

proc echoer_destroy*(e: Echoer) {.ffiDtor.} =
  discard

genBindings()
