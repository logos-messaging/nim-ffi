## A recycle that cannot finish quarantines the slot. The host polling that
## context must still learn it ended, with the reason, rather than wait forever.

import std/[atomics, os]
import unittest2
import results
import ffi
import ./helpers

type QuarantineLib = object

var handlerStarted: Atomic[bool]

registerReqFFI(HangRequest, lib: ptr QuarantineLib):
  proc(): Future[Result[string, string]] {.async.} =
    handlerStarted.store(true)
    # Outlives both drain rounds, so the recycle gives up and quarantines.
    await sleepAsync(10.seconds)
    return ok("too late")

# Module scope: a quarantined slot is never given back, and its buffers must
# stay reachable for LeakSanitizer.
var pool: FFIContextPool[QuarantineLib]

suite "a quarantined context still ends for its poller":
  test "poll reports CLOSED with the reason after a recycle is abandoned":
    let created = pool.createFFIContext()
    check created.isOk()
    if created.isOk():
      let ctx = created.value
      let generation = ctx.currentGeneration()
      check sendRequestToFFIThread(ctx, HangRequest.ffiNewReq(noopCallback, nil)).isOk()
      # The recycle must find the handler running, or there is nothing to drain.
      for _ in 0 ..< 200:
        if handlerStarted.load():
          break
        sleep(10)
      check handlerStarted.load()

      check pool.recycleFFIContext(ctx).isErr()
      check ctx.lifecycle.load() == CtxLifecycle.RecycleFailed

      var msg: ptr NimFfiMsg
      var ret = RET_OK
      # Whatever the owner produced first still arrives; the end comes last.
      for _ in 0 ..< 16:
        ret = pollContext(ctx, generation, 2000, addr msg)
        if ret != RET_OK:
          break
      check ret == RET_CLOSED
      check not msg.isNil()
      if ret == RET_CLOSED and not msg.isNil():
        check msg.kind == MsgClosed
        check msg.retCode == RET_ERR
        var reason = newString(int(msg.len))
        if msg.len > 0:
          copyMem(addr reason[0], msg.payload, int(msg.len))
        check reason == "in-flight handlers did not drain"
