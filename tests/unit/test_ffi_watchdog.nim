## Liveness is reported by `poll`: it reads the FFI thread's heartbeat on the
## host's thread, so a wedged FFI thread is reported without any thread of ours.

import std/[atomics, os]
import unittest2
import results
import ffi
import ./helpers

type TestWatchLib = object

var gBlockingEnabled: Atomic[bool]

registerReqFFI(BlockingRequest, lib: ptr TestWatchLib):
  proc(milliseconds: int): Future[Result[string, string]] {.async.} =
    if gBlockingEnabled.load():
      os.sleep(milliseconds)
    return ok("done")

when not defined(gcRefc):
  ## Skipped under refc: sleeping the FFI thread in a sync handler misbehaves there.
  suite "FFI heartbeat staleness":
    test "a wedged FFI thread is reported, and so is its recovery":
      setupCallbackData(rsp)

      var pool: FFIContextPool[TestWatchLib]
      let ctx = pool.createFFIContext().valueOr:
        check false
        return
      defer:
        # Disable the wedge first so destroy isn't blocked by the sleeping handler.
        gBlockingEnabled.store(false)
        discard pool.destroyFFIContext(ctx)

      # The first poll starts the watch; nothing is reported during the start delay.
      let startDelayMs = FFIHeartbeatStartDelay.milliseconds.int
      check pollMsg(ctx, startDelayMs + 200).ret == RET_TIMEOUT

      gBlockingEnabled.store(true)
      let wedgeMs = FFIHeartbeatStaleThreshold.milliseconds.int + 2500
      check sendRequestToFFIThread(
        ctx, BlockingRequest.ffiNewReq(testCallback, addr rsp, wedgeMs)
      )
        .isOk()

      let stale = pollMsg(ctx, wedgeMs)
      check stale.ret == RET_OK
      check stale.kind == MsgNotResponding
      check stale.aux == NotRespondingHeartbeat

      waitCallback(rsp)
      gBlockingEnabled.store(false)

      let recovered = pollMsg(ctx, 3000)
      check recovered.ret == RET_OK
      check recovered.kind == MsgResponding
