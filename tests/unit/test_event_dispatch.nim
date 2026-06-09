## Tests for the CBOR-style FFI event dispatch path:
##   - `dispatchFFIEvent` accepts both `string` and `seq[byte]` bodies
##   - `dispatchFFIEventCbor` wraps a typed payload in `EventEnvelope[T]`,
##     CBOR-encodes it, and dispatches via the event callback
##
## Tests run end-to-end against a real FFI thread (via FFIContextPool +
## sendRequestToFFIThread) so we exercise the threadvar-backed
## ffiCurrentEventRegistry wiring, not just the templates in isolation.

import std/[locks, os]
import unittest2
import results
import ffi

type TestEvtLib = object

## Event payload type (would be `{.ffi.}` in production so the codec gen
## emits a matching struct on the foreign side; the test only needs CBOR
## round-trip, which `cborEncode`/`cborDecode` provide via cbor_serial's
## generic overloads).
type MessageSentBody* {.ffi.} = object
  requestId*: string
  messageHash*: string

## Same callback-state helper as test_ffi_context.nim, duplicated here so
## this file stays a self-contained test binary.
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

proc callbackBytes(d: var CallbackData): seq[byte] =
  var bytes = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr bytes[0], addr d.msg[0], d.msgLen)
  bytes

## A request that dispatches a typed CBOR event from inside the FFI
## thread and then returns ok — so the response callback can be used to
## synchronize the test.
registerReqFFI(EmitCborEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEventCbor(
      "message_sent", MessageSentBody(requestId: "req-1", messageHash: "0xdeadbeef")
    )
    return ok("emitted")

## A request that uses the lower-level `dispatchFFIEvent` with a raw
## `seq[byte]` body — the path that previously rejected non-string bodies.
registerReqFFI(EmitRawBytesEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEvent("raw_bytes"):
      @[byte 0x01, 0x02, 0x03]
    return ok("emitted")

## Setter-thread worker for the registry race regression test. Each
## iteration adds then immediately removes a listener for the dispatched
## event so a TSan-instrumented build can confirm `FFIEventRegistry.lock`
## serialises the cross-thread mutation against dispatch-time
## `snapshotListeners` reads from the FFI thread.
type SetterArgs =
  tuple[
    ctx: ptr FFIContext[TestEvtLib], stop: ptr Atomic[bool], target: ptr CallbackData
  ]

proc setterThreadBody(args: SetterArgs) {.thread.} =
  while not args.stop[].load():
    let id =
      addEventListener(args.ctx[].eventRegistry, "message_sent", captureCb, args.target)
    discard removeEventListener(args.ctx[].eventRegistry, id)

suite "dispatchFFIEventCbor":
  test "delivers EventEnvelope-shaped CBOR payload to event callback":
    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var evt: CallbackData
    initCallbackData(evt)
    defer:
      deinitCallbackData(evt)

    # Subscribe to the specific event the request below dispatches.
    discard addEventListener(ctx[].eventRegistry, "message_sent", captureCb, addr evt)

    # Trigger the dispatch from the FFI thread; the response callback is
    # ignored (we only care that the request completed so we know the event
    # has fired).
    var rsp: CallbackData
    initCallbackData(rsp)
    defer:
      deinitCallbackData(rsp)

    check sendRequestToFFIThread(
      ctx, EmitCborEventRequest.ffiNewReq(captureCb, addr rsp)
    )
      .isOk()
    waitCallback(rsp)
    waitCallback(evt)

    check evt.retCode == RET_OK
    let decoded = cborDecode(callbackBytes(evt), EventEnvelope[MessageSentBody])
    check decoded.isOk()
    check decoded.value.eventType == "message_sent"
    check decoded.value.payload.requestId == "req-1"
    check decoded.value.payload.messageHash == "0xdeadbeef"

suite "dispatchFFIEvent with seq[byte]":
  test "accepts a raw seq[byte] body":
    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var evt: CallbackData
    initCallbackData(evt)
    defer:
      deinitCallbackData(evt)

    discard addEventListener(ctx[].eventRegistry, "raw_bytes", captureCb, addr evt)

    var rsp: CallbackData
    initCallbackData(rsp)
    defer:
      deinitCallbackData(rsp)

    check sendRequestToFFIThread(
      ctx, EmitRawBytesEventRequest.ffiNewReq(captureCb, addr rsp)
    )
      .isOk()
    waitCallback(rsp)
    waitCallback(evt)

    check evt.retCode == RET_OK
    check callbackBytes(evt) == @[byte 0x01, 0x02, 0x03]

when not defined(gcRefc):
  ## Skipped under `--mm:refc`: each setter thread grows / shrinks the
  ## per-event listener `seq[FFIEventListener]` via `addEventListener`,
  ## and refc's per-thread GC heap ownership makes cross-thread seq
  ## buffer reallocation unsafe even when the surrounding lock is held.
  ## ORC + the FFI thread + tsan (the combo this test was written for)
  ## does not have that limitation.
  suite "FFIEventRegistry concurrent access":
    ## Regression for PR #39 review comments r3288220895 / r3289285387.
    ## Run under tsan to actually validate the fix:
    ##   NIM_FFI_SAN=tsan NIM_FFI_MM=orc nimble test_sanitized
    test "concurrent add/remove writers vs dispatch reads stay race-free":
      var pool: FFIContextPool[TestEvtLib]
      let ctx = pool.createFFIContext().valueOr:
        check false
        return
      defer:
        discard pool.destroyFFIContext(ctx)

      var evt: CallbackData
      initCallbackData(evt)
      defer:
        deinitCallbackData(evt)

      # Seed an initial callback so the FFI thread's first dispatch has a
      # target. The setter threads will then repeatedly re-install the same
      # (callback, userData) pair — what matters is the cross-thread write
      # racing the FFI thread's read, not which pair "wins".
      discard addEventListener(ctx[].eventRegistry, "message_sent", captureCb, addr evt)

      const NumSetterThreads = 4
      const NumDispatchIters = 200

      var stop: Atomic[bool]
      stop.store(false)
      var setters: array[NumSetterThreads, Thread[SetterArgs]]
      for i in 0 ..< NumSetterThreads:
        createThread(setters[i], setterThreadBody, (ctx, addr stop, addr evt))

      var rsp: CallbackData
      initCallbackData(rsp)
      defer:
        deinitCallbackData(rsp)

      for _ in 0 ..< NumDispatchIters:
        # Reset rsp so each iteration's `waitCallback` blocks until the
        # FFI thread fires the response — keeps the loop synchronous.
        acquire(rsp.lock)
        rsp.called = false
        release(rsp.lock)

        check sendRequestToFFIThread(
          ctx, EmitCborEventRequest.ffiNewReq(captureCb, addr rsp)
        )
          .isOk()
        waitCallback(rsp)

      stop.store(true)
      for i in 0 ..< NumSetterThreads:
        joinThread(setters[i])

      # `evt` got hit by every dispatch above; just confirm at least one
      # actually landed so a silently-broken dispatch loop is caught.
      check evt.called

## A foreign-thread mutation must not be able to invalidate the
## listener's `userData` while an in-flight dispatch is mid-invocation.
## The dispatch templates hold `reg.lock` for the entire snapshot +
## invocation, so foreign `removeEventListener` blocks until dispatch
## returns.

type SlowState = object
  entered: Atomic[bool]
  exited: Atomic[bool]

proc slowEventCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Signal entry, sleep briefly (the window during which the main
  ## thread must call removeEventListener and block), signal exit.
  let st = cast[ptr SlowState](userData)
  st[].entered.store(true)
  os.sleep(15)
  st[].exited.store(true)

type DispatcherArgs = tuple[reg: ptr FFIEventRegistry, done: ptr Atomic[bool]]

proc dispatcherBody(args: DispatcherArgs) {.thread.} =
  ffiCurrentEventRegistry = args.reg
  dispatchFFIEvent("evt"):
    "payload"
  args.done[].store(true)

suite "registry lock held during invocation":
  test "removeEventListener blocks until in-flight dispatch finishes":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)

    var st: SlowState
    st.entered.store(false)
    st.exited.store(false)

    let id = addEventListener(reg, "evt", slowEventCb, addr st)
    check id != 0'u64

    var done: Atomic[bool]
    done.store(false)
    var thr: Thread[DispatcherArgs]
    createThread(thr, dispatcherBody, (addr reg, addr done))

    # Wait until the worker thread is inside slowEventCb.
    for _ in 0 ..< 200:
      if st.entered.load():
        break
      os.sleep(1)
    check st.entered.load()
    check not st.exited.load()

    # Lock-during-invocation contract: remove blocks until dispatch
    # finishes; by the time it returns, slowEventCb has set exited=true.
    check removeEventListener(reg, id)
    check st.exited.load()
    joinThread(thr)
    check done.load()

suite "liveness events":
  ## `onNotResponding` / `onResponding` bypass the event queue and dispatch
  ## directly to listeners — the queue itself may be wedged behind the same
  ## stall they're signalling. These tests pin down the wire shape (event
  ## name + CBOR-encoded `EventEnvelope[…]`) so a future refactor can't
  ## silently break consumers polling for the "library hung" signal.
  test "onNotResponding delivers EventEnvelope[NotRespondingEvent] to subscribers":
    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var evt: CallbackData
    initCallbackData(evt)
    defer:
      deinitCallbackData(evt)

    discard
      addEventListener(ctx[].eventRegistry, NotRespondingEventName, captureCb, addr evt)

    onNotResponding(ctx)

    waitCallback(evt)
    check evt.retCode == RET_OK
    let decoded = cborDecode(callbackBytes(evt), EventEnvelope[NotRespondingEvent])
    check decoded.isOk()
    check decoded.value.eventType == NotRespondingEventName

  test "onResponding delivers EventEnvelope[RespondingEvent] to subscribers":
    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var evt: CallbackData
    initCallbackData(evt)
    defer:
      deinitCallbackData(evt)

    discard
      addEventListener(ctx[].eventRegistry, RespondingEventName, captureCb, addr evt)

    onResponding(ctx)

    waitCallback(evt)
    check evt.retCode == RET_OK
    let decoded = cborDecode(callbackBytes(evt), EventEnvelope[RespondingEvent])
    check decoded.isOk()
    check decoded.value.eventType == RespondingEventName

  test "liveness events with no subscriber are a no-op":
    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)
    # No listener registered — must not crash, must not block.
    onNotResponding(ctx)
    onResponding(ctx)

suite "event thread drains queued events":
  ## The event thread wakes every `EventThreadTickInterval` (or on
  ## `eventQueueSignal`, not exported) and drains `eventQueue` into the
  ## registered listeners. This test pushes a c_malloc'd payload onto the
  ## queue from the test thread and waits for the tick-driven drain to
  ## deliver it — exercises the `tryEnqueueEvent` → `drainEventQueue` →
  ## `dispatchQueuedEvent` → listener path end-to-end.
  test "enqueued event is delivered to subscriber within a tick":
    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var evt: CallbackData
    initCallbackData(evt)
    defer:
      deinitCallbackData(evt)

    const QueuedEvtName = "queued_evt"
    discard addEventListener(ctx[].eventRegistry, QueuedEvtName, captureCb, addr evt)

    # `tryEnqueueEvent` takes ownership of both buffers on success; the
    # event thread c_frees them after dispatch returns.
    let nameBuf = alloc(QueuedEvtName)
    let payload = @[byte 0xDE, 0xAD, 0xBE, 0xEF]
    var shared = allocSharedSeq(payload)
    check tryEnqueueEvent(ctx[].eventQueue, nameBuf, shared.data, shared.len)

    waitCallback(evt)
    check evt.retCode == RET_OK
    check callbackBytes(evt) == payload
