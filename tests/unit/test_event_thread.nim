## Integration tests for the dedicated event thread (issue #6).

import std/[atomics, locks, os, strutils]
import unittest2
import results
import ffi

type TestEvtLib = object

type LatchPayload* {.ffi.} = object
  iter*: int

type CallbackData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  msg: array[1024, byte]
  msgLen: int

proc initCallbackData(d: var CallbackData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitCallbackData(d: var CallbackData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

template setupCallbackData(name: untyped) =
  ## Declares `name`, inits it, and defers its deinit in the caller's scope.
  var name: CallbackData
  initCallbackData(name)
  defer:
    deinitCallbackData(name)

proc captureCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].retCode = retCode
  let n = min(int(len), d[].msg.len)
  if n > 0 and not msg.isNil():
    copyMem(addr d[].msg[0], msg, n)
  d[].msgLen = n
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc waitCallback(d: var CallbackData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc resetCalled(d: var CallbackData) =
  acquire(d.lock)
  d.called = false
  release(d.lock)

proc waitCallbackTimeout(d: var CallbackData, timeoutMs: int): bool =
  ## Polls under `d.lock` so the load syncs with the `captureCb` writer.
  let deadline = Moment.now() + timeoutMs.milliseconds
  while true:
    acquire(d.lock)
    let done = d.called
    release(d.lock)
    if done:
      return true
    if Moment.now() >= deadline:
      return false
    os.sleep(10)

template withPool(ctxIdent: untyped, body: untyped) =
  ## Sets up a pool + ctx, runs body, destroys on exit.
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

# Atomic switch so the wedge fires deterministically per test.
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
    # CallbackData defers declared first run last (LIFO): pool-destroy joins
    # the event thread before any still-held mutex is torn down. TSan otherwise
    # flags `captureCb` on a destroyed mutex.
    setupCallbackData(evt)
    setupCallbackData(rsp)

    withPool(ctx):
      discard
        addEventListener(ctx[].eventRegistry, "latch", captureThreadIdCb, addr evt)

      check sendRequestToFFIThread(
        ctx, CaptureFfiTidRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)

      resetCalled(rsp)
      check sendRequestToFFIThread(
        ctx, EmitLatchEvent.ffiNewReq(captureCb, addr rsp, 0)
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
        ctx, EmitLatchEvent.ffiNewReq(captureCb, addr rsp, 0)
      )
        .isOk()
      waitCallback(rsp)
      resetCalled(rsp)

      # chronos's `Moment` — std/times exports a `milliseconds` that
      # shadows chronos's at this generic-instantiation site.
      let started = Moment.now()
      check sendRequestToFFIThread(ctx, PingEvent.ffiNewReq(captureCb, addr rsp)).isOk()
      waitCallback(rsp)
      let elapsed = Moment.now() - started

      check elapsed < 100.milliseconds # under the 150 ms slow-listener sleep

when not defined(gcRefc):
  ## Skipped under refc: sleeping the FFI thread inside a sync handler
  ## interacts badly with refc + existing destroy-on-time policies.
  suite "FFI heartbeat staleness":
    test "wedged FFI thread triggers onNotResponding via heartbeat":
      setupCallbackData(notif)
      setupCallbackData(rsp)

      var pool: FFIContextPool[TestEvtLib]
      let ctx = pool.createFFIContext().valueOr:
        check false
        return
      defer:
        # Disable wedge first so destroy isn't blocked by the still-sleeping handler.
        gBlockingEnabled.store(false)
        discard pool.destroyFFIContext(ctx)

      discard addEventListener(
        ctx[].eventRegistry, NotRespondingEventName, captureCb, addr notif
      )

      # Wait out the start-delay so the heartbeat check is armed.
      os.sleep(FFIHeartbeatStartDelay.milliseconds.int + 200)

      # Wedge long enough to cross at least one tick boundary.
      gBlockingEnabled.store(true)
      let wedgeMs =
        (EventThreadTickInterval + FFIHeartbeatStaleThreshold).milliseconds.int + 1500
      check sendRequestToFFIThread(
        ctx, BlockingRequest.ffiNewReq(captureCb, addr rsp, wedgeMs)
      )
        .isOk()
      waitCallback(rsp)
      gBlockingEnabled.store(false)

      check waitCallbackTimeout(notif, 1500)

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
  ## First call signals entered then blocks under reg.lock to back-pressure
  ## subsequent dispatches — gives a deterministic way to fill the queue.
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

suite "queue overflow":
  test "overflow sets stuck flag, fires onNotResponding, rejects new requests":
    var bp: BackpressureState
    initBackpressure(bp)
    defer:
      deinitBackpressure(bp)

    setupCallbackData(notif)
    setupCallbackData(rsp)
    setupCallbackData(rejected)

    withPool(ctx):
      discard addEventListener(ctx[].eventRegistry, "latch", backpressureCb, addr bp)
      discard addEventListener(
        ctx[].eventRegistry, NotRespondingEventName, captureCb, addr notif
      )

      # Kick one event so the listener holds reg.lock; subsequent enqueues
      # pile up undrained.
      check sendRequestToFFIThread(
        ctx, EmitLatchEvent.ffiNewReq(captureCb, addr rsp, -1)
      )
        .isOk()
      waitCallback(rsp)

      acquire(bp.enteredLock)
      while not bp.entered.load():
        wait(bp.enteredCond, bp.enteredLock)
      release(bp.enteredLock)

      # Burst > capacity in one request; tail enqueues flip the stuck flag.
      resetCalled(rsp)
      check sendRequestToFFIThread(
        ctx, BurstEmit.ffiNewReq(captureCb, addr rsp, EventQueueCapacity + 8)
      )
        .isOk()
      waitCallback(rsp)

      check ctx.eventQueueStuck.load()

      let res =
        sendRequestToFFIThread(ctx, PingEvent.ffiNewReq(captureCb, addr rejected))
      check res.isErr()
      check res.error.contains("stuck")

      # Release backpressure so drain advances and the stuck flag fires
      # not_responding.
      acquire(bp.releaseLock)
      bp.release.store(true)
      signal(bp.releaseCond)
      release(bp.releaseLock)

      check waitCallbackTimeout(notif, 2000)
