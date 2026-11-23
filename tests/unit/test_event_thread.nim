## Integration tests for the dedicated event thread (issue #6).

import std/[atomics, locks, os, strutils]
import unittest2
import results
import ffi
import ./helpers

type TestEvtLib = object

type LatchPayload* {.ffi.} = object
  iter*: int

template withPool(ctxIdent: untyped, body: untyped) =
  var pool: FFIContextPool[TestEvtLib]
  let ctxIdent = pool.createFFIContext().valueOr:
    check false
    return
  defer:
    discard pool.destroyFFIContext(ctxIdent)
  body

registerReqFFI(EmitLatchEvent, lib: ptr TestEvtLib):
  proc(iter: int): Future[Result[string, string]] {.async.} =
    dispatchFFIEventCbor("latch", LatchPayload(iter: iter))
    return ok("emitted")

registerReqFFI(PingEvent, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("pong")

var gBlockingEnabled: Atomic[bool]
gBlockingEnabled.store(false)

registerReqFFI(BlockingRequest, lib: ptr TestEvtLib):
  proc(milliseconds: int): Future[Result[string, string]] {.async.} =
    if gBlockingEnabled.load():
      os.sleep(milliseconds)
    return ok("done")

var gListenerThreadId: Atomic[int]
gListenerThreadId.store(-1)

proc captureThreadIdCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  gListenerThreadId.store(getThreadId())
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

var gFfiThreadId: Atomic[int]
gFfiThreadId.store(-1)

registerReqFFI(CaptureFfiTidRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    gFfiThreadId.store(getThreadId())
    return ok("captured")

suite "event delivery is asynchronous":
  test "listener runs on the event thread, not the FFI thread":
    # LIFO defer order: pool-destroy joins the event thread before mutex teardown.
    setupCallbackData(evt)
    setupCallbackData(rsp)

    withPool(ctx):
      discard
        addEventListener(ctx[].eventRegistry, "latch", captureThreadIdCb, addr evt)

      check sendRequestToFFIThread(
        ctx, CaptureFfiTidRequest.ffiNewReq(testCallback, addr rsp)
      )
        .isOk()
      waitCallback(rsp)

      resetCalled(rsp)
      check sendRequestToFFIThread(
        ctx, EmitLatchEvent.ffiNewReq(testCallback, addr rsp, 0)
      )
        .isOk()
      waitCallback(rsp)
      waitCallback(evt)

      let ffiTid = gFfiThreadId.load()
      let listenerTid = gListenerThreadId.load()
      check ffiTid >= 0
      check listenerTid >= 0
      check ffiTid != listenerTid

proc slowSleepCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  os.sleep(150)

suite "FFI thread independence":
  test "slow listener does not block FFI thread request round-trip":
    setupCallbackData(rsp)

    withPool(ctx):
      discard addEventListener(ctx[].eventRegistry, "latch", slowSleepCb, nil)

      check sendRequestToFFIThread(
        ctx, EmitLatchEvent.ffiNewReq(testCallback, addr rsp, 0)
      )
        .isOk()
      waitCallback(rsp)
      resetCalled(rsp)

      let started = Moment.now()
      check sendRequestToFFIThread(ctx, PingEvent.ffiNewReq(testCallback, addr rsp))
        .isOk()
      waitCallback(rsp)
      let elapsed = Moment.now() - started

      check elapsed < 100.milliseconds # under the 150 ms slow-listener sleep

when not defined(gcRefc):
  ## Skipped under refc: sleeping the FFI thread in a sync handler misbehaves there.
  suite "FFI heartbeat staleness":
    test "wedged FFI thread triggers onNotResponding via heartbeat":
      setupCallbackData(notif)
      setupCallbackData(rsp)

      var pool: FFIContextPool[TestEvtLib]
      let ctx = pool.createFFIContext().valueOr:
        check false
        return
      defer:
        # Disable wedge first so destroy isn't blocked by the sleeping handler.
        gBlockingEnabled.store(false)
        discard pool.destroyFFIContext(ctx)

      discard addEventListener(
        ctx[].eventRegistry, NotRespondingEventName, testCallback, addr notif
      )

      # Wait out the start-delay so the heartbeat check is armed.
      os.sleep(FFIHeartbeatStartDelay.milliseconds.int + 200)

      gBlockingEnabled.store(true)
      let wedgeMs =
        # long enough to cross a tick boundary
        (EventThreadTickInterval + FFIHeartbeatStaleThreshold).milliseconds.int + 1500
      check sendRequestToFFIThread(
        ctx, BlockingRequest.ffiNewReq(testCallback, addr rsp, wedgeMs)
      )
        .isOk()
      waitCallback(rsp)
      gBlockingEnabled.store(false)

      check waitCallbackTimeout(notif, 1500)
      let decoded = cborDecode(payload(notif), EventEnvelope[NotRespondingEvent])
      check decoded.isOk()
      check decoded.value.payload.reason == NotRespondingReason.heartbeat

type BackpressureState = object
  enteredLock: Lock
  enteredCond: Cond
  entered: Atomic[bool]
  releaseLock: Lock
  releaseCond: Cond
  release: Atomic[bool]

proc initBackpressure(b: var BackpressureState) =
  b.enteredLock.initLock()
  b.enteredCond.initCond()
  b.releaseLock.initLock()
  b.releaseCond.initCond()

proc deinitBackpressure(b: var BackpressureState) =
  b.enteredCond.deinitCond()
  b.enteredLock.deinitLock()
  b.releaseCond.deinitCond()
  b.releaseLock.deinitLock()

proc backpressureCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## First call signals entered then blocks the drain to fill the queue.
  let b = cast[ptr BackpressureState](userData)
  if not b[].entered.exchange(true):
    acquire(b[].enteredLock)
    signal(b[].enteredCond)
    release(b[].enteredLock)

    acquire(b[].releaseLock)
    while not b[].release.load():
      wait(b[].releaseCond, b[].releaseLock)
    release(b[].releaseLock)

registerReqFFI(BurstEmit, lib: ptr TestEvtLib):
  proc(count: int): Future[Result[string, string]] {.async.} =
    for i in 0 ..< count:
      dispatchFFIEventCbor("latch", LatchPayload(iter: i))
    return ok("bursted")

var gFlooding: Atomic[bool]

registerReqFFI(FloodFor, lib: ptr TestEvtLib):
  proc(ms: int): Future[Result[string, string]] {.async.} =
    gFlooding.store(true)
    defer:
      gFlooding.store(false)
    let deadline = Moment.now() + ms.milliseconds
    while Moment.now() < deadline:
      for i in 0 ..< EventQueueCapacity:
        dispatchFFIEventCbor("flood", LatchPayload(iter: i))
      # Yield so the heartbeat keeps beating and only the overflow reports.
      await sleepAsync(1.milliseconds)
    return ok("flooded")

proc floodGatedListener(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  waitNextDrop(cast[ptr EventQueue](userData)[], gFlooding)

suite "queue overflow":
  test "a burst overflow drops and counts, requests still run, no notice":
    var bp: BackpressureState
    initBackpressure(bp)
    defer:
      deinitBackpressure(bp)

    setupCallbackData(notif)
    setupCallbackData(rsp)

    withPool(ctx):
      discard addEventListener(ctx[].eventRegistry, "latch", backpressureCb, addr bp)
      discard addEventListener(
        ctx[].eventRegistry, NotRespondingEventName, testCallback, addr notif
      )

      # Listener blocks the drain so later enqueues pile up undrained.
      check sendRequestToFFIThread(
        ctx, EmitLatchEvent.ffiNewReq(testCallback, addr rsp, -1)
      )
        .isOk()
      waitCallback(rsp)

      acquire(bp.enteredLock)
      while not bp.entered.load():
        wait(bp.enteredCond, bp.enteredLock)
      release(bp.enteredLock)

      resetCalled(rsp)
      check sendRequestToFFIThread(
        ctx, BurstEmit.ffiNewReq(testCallback, addr rsp, EventQueueCapacity + 8)
      )
        .isOk()
      waitCallback(rsp)
      # The blocked listener pins its event's slot, so one more burst event is lost.
      check ctx.eventDrops() == EventDrops(ringFull: 9)

      resetCalled(rsp)
      check sendRequestToFFIThread(ctx, PingEvent.ffiNewReq(testCallback, addr rsp))
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_OK

      acquire(bp.releaseLock)
      bp.release.store(true)
      signal(bp.releaseCond)
      release(bp.releaseLock)

      check not waitCallbackTimeout(notif, 2 * EventOverflowSustainMs)

  test "sustained drops fire onNotResponding once, then onResponding":
    setupCallbackData(notif)
    setupCallbackData(back)
    setupCallbackData(rsp)

    withPool(ctx):
      discard addEventListener(
        ctx[].eventRegistry, "flood", floodGatedListener, addr ctx[].eventQueue
      )
      discard addEventListener(
        ctx[].eventRegistry, NotRespondingEventName, testCallback, addr notif
      )
      discard addEventListener(
        ctx[].eventRegistry, RespondingEventName, testCallback, addr back
      )

      check sendRequestToFFIThread(
        ctx, FloodFor.ffiNewReq(testCallback, addr rsp, 3 * EventOverflowSustainMs)
      )
        .isOk()

      check waitCallbackTimeout(notif, 4 * EventOverflowSustainMs)
      let decoded = cborDecode(payload(notif), EventEnvelope[NotRespondingEvent])
      check decoded.isOk()
      check decoded.value.payload.reason == NotRespondingReason.queueFull
      waitCallback(rsp)
      check rsp.retCode == RET_OK
      check ctx.eventDrops().ringFull > 0

      check waitCallbackTimeout(back, 6 * EventOverflowSustainMs)
      let ended = cborDecode(payload(back), EventEnvelope[RespondingEvent])
      check ended.isOk()
      check ended.value.payload.reason == NotRespondingReason.queueFull
