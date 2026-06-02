## Integration tests for the dedicated event thread introduced by
## issue #6. Each test stands up a real `FFIContext` (via
## `FFIContextPool`) and exercises the FFI thread → bounded queue →
## event thread → listener pipeline end to end.

import std/[atomics, locks, os, strutils]
import unittest2
import results
import ffi

type TestEvtLib = object

type LatchPayload* {.ffi.} = object
  iter*: int

## Captured-state callback identical to the helpers in
## `test_event_dispatch.nim`, repeated here so this file stays a
## self-contained test binary.
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

proc captureCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].retCode = retCode
  let n = min(int(len), d[].msg.len)
  if n > 0 and not msg.isNil:
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

proc waitCallbackTimeout(d: var CallbackData, timeoutMs: int): bool =
  ## Polling variant for tests where the callback may legitimately
  ## never fire — returns true if observed `called` within the budget,
  ## false on timeout. Polls in 10 ms increments under `d.lock` so the
  ## load is synchronised with the `captureCb` writer.
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

# ---------------------------------------------------------------------------
# Request helpers
# ---------------------------------------------------------------------------

registerReqFFI(EmitLatchEvent, lib: ptr TestEvtLib):
  proc(iter: int): Future[Result[string, string]] {.async.} =
    dispatchFFIEventCbor("latch", LatchPayload(iter: iter))
    return ok("emitted")

## A request whose async body completes immediately — useful for
## probing FFI-thread round-trip latency under load.
registerReqFFI(PingEvent, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("pong")

## A request whose async body blocks the FFI thread synchronously
## (no await) so the heartbeat freezes. Used to exercise the new
## heartbeat-staleness path. Guarded by an Atomic switch so we can
## enable it deterministically per test rather than turning every
## test of this request type into a watchdog probe.
var gBlockingEnabled: Atomic[bool]
gBlockingEnabled.store(false)

registerReqFFI(BlockingRequest, lib: ptr TestEvtLib):
  proc(milliseconds: int): Future[Result[string, string]] {.async.} =
    if gBlockingEnabled.load():
      os.sleep(milliseconds)
    return ok("done")

# ---------------------------------------------------------------------------
# Thread-id capture
# ---------------------------------------------------------------------------

var gListenerThreadId: Atomic[int]
gListenerThreadId.store(-1)

proc captureThreadIdCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Records the OS thread id of the listener invocation, so the test
  ## can assert it differs from the FFI thread's id.
  gListenerThreadId.store(getThreadId())
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

## Returns the FFI thread's id by running a no-op request and reading
## `getThreadId()` from inside the handler. Used to compare against
## the listener's thread id below.
var gFfiThreadId: Atomic[int]
gFfiThreadId.store(-1)

registerReqFFI(CaptureFfiTidRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    gFfiThreadId.store(getThreadId())
    return ok("captured")

suite "event delivery is asynchronous":
  test "listener runs on the event thread, not the FFI thread":
    # CallbackData defers come BEFORE the pool-destroy defer so they run
    # AFTER it (LIFO): the event thread is joined before any lock the
    # event thread might still be holding is torn down — otherwise TSan
    # flags `captureCb` accessing an already-destroyed mutex.
    var evt: CallbackData
    initCallbackData(evt)
    defer:
      deinitCallbackData(evt)

    var rsp: CallbackData
    initCallbackData(rsp)
    defer:
      deinitCallbackData(rsp)

    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    discard addEventListener(
      ctx[].eventRegistry, "latch", captureThreadIdCb, addr evt
    )

    # Capture the FFI thread id.
    check sendRequestToFFIThread(
      ctx, CaptureFfiTidRequest.ffiNewReq(captureCb, addr rsp)
    )
      .isOk()
    waitCallback(rsp)

    # Now emit an event from the FFI thread and wait for the listener.
    acquire(rsp.lock)
    rsp.called = false
    release(rsp.lock)
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

# ---------------------------------------------------------------------------
# Slow listener does not block the FFI thread
# ---------------------------------------------------------------------------

proc slowSleepCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Sleeps long enough that we'd notice if the FFI thread were waiting
  ## on us before accepting the next request.
  os.sleep(150)

suite "FFI thread independence":
  test "slow listener does not block FFI thread request round-trip":
    var rsp: CallbackData
    initCallbackData(rsp)
    defer:
      deinitCallbackData(rsp)

    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    discard addEventListener(
      ctx[].eventRegistry, "latch", slowSleepCb, nil
    )

    # Fire an event, then immediately fire a ping request. With dispatch
    # off the FFI thread, the ping must complete in well under 150 ms
    # even though the prior event is still in flight on the event thread.
    check sendRequestToFFIThread(
      ctx, EmitLatchEvent.ffiNewReq(captureCb, addr rsp, 0)
    )
      .isOk()
    waitCallback(rsp)

    acquire(rsp.lock)
    rsp.called = false
    release(rsp.lock)

    # Use chronos's Moment for timing so we don't pull std/times into
    # scope — std/times exports a `milliseconds` proc that shadows the
    # chronos one used inside the FFI thread body, breaking compilation
    # of generic instantiations at this call site.
    let started = Moment.now()
    check sendRequestToFFIThread(ctx, PingEvent.ffiNewReq(captureCb, addr rsp))
      .isOk()
    waitCallback(rsp)
    let elapsed = Moment.now() - started

    check elapsed < 100.milliseconds   # ample margin under the 150 ms slow-listener sleep

# ---------------------------------------------------------------------------
# Heartbeat staleness fires onNotResponding
# ---------------------------------------------------------------------------

when not defined(gcRefc):
  ## Skipped under `--mm:refc`: this test relies on `os.sleep`ing the
  ## FFI thread for several seconds inside a synchronous handler.
  ## refc plus the existing destroy-on-time policies make that
  ## combination flaky in CI; the orc path is the contract we care
  ## about here.
  suite "FFI heartbeat staleness":
    test "wedged FFI thread triggers onNotResponding via heartbeat":
      # Lock-bearing CallbackData defers are declared FIRST so they run
      # LAST (LIFO); pool-destroy runs FIRST and joins the event thread
      # before any mutex it might still be holding is destroyed.
      var notif: CallbackData
      initCallbackData(notif)
      defer:
        deinitCallbackData(notif)

      var rsp: CallbackData
      initCallbackData(rsp)
      defer:
        deinitCallbackData(rsp)

      var pool: FFIContextPool[TestEvtLib]
      let ctx = pool.createFFIContext().valueOr:
        check false
        return
      defer:
        # Disable the wedge before tearing down so destroy isn't blocked
        # by the still-sleeping handler.
        gBlockingEnabled.store(false)
        discard pool.destroyFFIContext(ctx)

      # Subscribe to the exact event name `onNotResponding` looks up so
      # the captured signal can't be ambiguously satisfied by an unrelated
      # event the test happens to dispatch.
      discard addEventListener(
        ctx[].eventRegistry, NotRespondingEventName, captureCb, addr notif
      )

      # Wait out the start-delay grace window first so the heartbeat
      # check is actually armed.
      os.sleep(FFIHeartbeatStartDelay.milliseconds.int + 200)

      # Wedge the FFI thread for longer than EventThreadTickInterval +
      # FFIHeartbeatStaleThreshold so the event thread observes a
      # frozen heartbeat across at least one tick boundary.
      gBlockingEnabled.store(true)
      let wedgeMs =
        (EventThreadTickInterval + FFIHeartbeatStaleThreshold).milliseconds.int +
          1500
      check sendRequestToFFIThread(
        ctx, BlockingRequest.ffiNewReq(captureCb, addr rsp, wedgeMs)
      )
        .isOk()
      waitCallback(rsp)
      gBlockingEnabled.store(false)

      # The not_responding event should have been delivered while the
      # FFI thread was wedged. captureCb writes `called` under
      # `notif.lock`, so wait through the cond rather than reading it
      # raw — avoids both the data race and the just-missed-it window.
      check waitCallbackTimeout(notif, 1500)

# ---------------------------------------------------------------------------
# Queue overflow sets the stuck flag and rejects further requests
# ---------------------------------------------------------------------------

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
  ## First invocation signals entered and then blocks until released —
  ## holds the event thread inside `withLock reg.lock`, which back-pressures
  ## subsequent dispatches and gives us a deterministic way to fill the
  ## queue.
  let b = cast[ptr BackpressureState](userData)
  if not b[].entered.exchange(true):
    acquire(b[].enteredLock)
    signal(b[].enteredCond)
    release(b[].enteredLock)

    acquire(b[].releaseLock)
    while not b[].release.load():
      wait(b[].releaseCond, b[].releaseLock)
    release(b[].releaseLock)

## A request that does N back-to-back dispatches from the FFI thread.
## Used to push enough events at once that the queue saturates while
## the event thread is stuck inside the backpressure listener above.
registerReqFFI(BurstEmit, lib: ptr TestEvtLib):
  proc(count: int): Future[Result[string, string]] {.async.} =
    for i in 0 ..< count:
      dispatchFFIEventCbor("latch", LatchPayload(iter: i))
    return ok("bursted")

suite "queue overflow":
  test "overflow sets stuck flag, fires onNotResponding, rejects new requests":
    # Lock-bearing state defers come FIRST so they run LAST (LIFO);
    # pool destroy joins the event thread before any mutex still
    # referenced from a listener is torn down.
    var bp: BackpressureState
    initBackpressure(bp)
    defer:
      deinitBackpressure(bp)

    var notif: CallbackData
    initCallbackData(notif)
    defer:
      deinitCallbackData(notif)

    var rsp: CallbackData
    initCallbackData(rsp)
    defer:
      deinitCallbackData(rsp)

    var rejected: CallbackData
    initCallbackData(rejected)
    defer:
      deinitCallbackData(rejected)

    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    discard addEventListener(
      ctx[].eventRegistry, "latch", backpressureCb, addr bp
    )
    # Subscribe to the exact not_responding event name so the wait below
    # can't be falsely satisfied by a "latch" payload from the burst.
    discard addEventListener(
      ctx[].eventRegistry, NotRespondingEventName, captureCb, addr notif
    )

    # Kick off one event so the event thread enters backpressureCb and
    # holds reg.lock. Once that's confirmed, any subsequent enqueues
    # pile up in the queue without being drained.
    check sendRequestToFFIThread(
      ctx, EmitLatchEvent.ffiNewReq(captureCb, addr rsp, -1)
    )
      .isOk()
    waitCallback(rsp)

    acquire(bp.enteredLock)
    while not bp.entered.load():
      wait(bp.enteredCond, bp.enteredLock)
    release(bp.enteredLock)

    # Now flood the queue. EventQueueCapacity+8 dispatches in one
    # FFI-thread request, atomically from the queue's perspective: the
    # event thread can't drain anything because it's stuck inside the
    # first callback. The last several enqueues must hit the
    # queue-full path and flip the stuck flag.
    acquire(rsp.lock)
    rsp.called = false
    release(rsp.lock)
    check sendRequestToFFIThread(
      ctx, BurstEmit.ffiNewReq(captureCb, addr rsp, EventQueueCapacity + 8)
    )
      .isOk()
    waitCallback(rsp)

    # The stuck flag is set as soon as the first overflow happens;
    # subsequent sendRequestToFFIThread calls must short-circuit.
    check ctx.eventQueueStuck.load()

    let res =
      sendRequestToFFIThread(ctx, PingEvent.ffiNewReq(captureCb, addr rejected))
    check res.isErr()
    check res.error.contains("stuck")

    # Release backpressure so the event thread can drain, advance past
    # the backpressure listener, observe the stuck flag, and fire the
    # not_responding notification.
    acquire(bp.releaseLock)
    bp.release.store(true)
    signal(bp.releaseCond)
    release(bp.releaseLock)

    # The whole point of this test is that overflow surfaces the
    # not_responding signal — assert it actually fires within a
    # bounded window rather than letting the test silently pass.
    check waitCallbackTimeout(notif, 2000)
