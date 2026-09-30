## A host that polls rarely must hear about a stalled FFI thread on its first
## poll after the stall, not one poll later.

import std/[atomics, os]
import unittest2
import results
import ffi
import ./helpers

type LivenessLib = object

var wedgeStarted: Atomic[bool]

registerReqFFI(WedgeRequest, lib: ptr LivenessLib):
  proc(): Future[Result[string, string]] {.async.} =
    wedgeStarted.store(true)
    # Blocks the FFI thread itself, so it stops beating.
    os.sleep(3000)
    return ok("done")

proc pollKind(ctx: ptr FFIContext[LivenessLib], generation: uint): (cint, uint32) =
  var msg: ptr NimFfiMsg
  let ret = pollContext(ctx, generation, 0, addr msg)
  var kind = 0'u32
  if not msg.isNil():
    kind = msg.kind
  return (ret, kind)

var pool: FFIContextPool[LivenessLib]

suite "a stall is reported on the first poll that can see it":
  test "a poll long after the last one reports a thread that stopped meanwhile":
    let created = pool.createFFIContext()
    check created.isOk()
    if created.isOk():
      let ctx = created.value
      defer:
        discard pool.destroyFFIContext(ctx)
      let generation = ctx.currentGeneration()

      # The first poll starts watching; the thread is beating then.
      check pollKind(ctx, generation)[0] == RET_TIMEOUT
      sleep(int(FFIHeartbeatStartDelay.milliseconds) + 300)

      # The thread stalls while nobody polls.
      check sendRequestToFFIThread(ctx, WedgeRequest.ffiNewReq(noopCallback, nil)).isOk()
      for _ in 0 ..< 200:
        if wedgeStarted.load():
          break
        sleep(10)
      check wedgeStarted.load()
      sleep(int(FFIHeartbeatStaleThreshold.milliseconds) + 500)

      let (ret, kind) = pollKind(ctx, generation)
      check ret == RET_OK
      check kind == MsgNotRespondingHeartbeat

      # And the recovery once the handler lets go.
      sleep(3000)
      let (ret2, kind2) = pollKind(ctx, generation)
      check ret2 == RET_OK
      check kind2 == MsgResponding
