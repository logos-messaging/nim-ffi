## Tests for the CBOR-style FFI event dispatch path:
##   - `dispatchFFIEvent` accepts both `string` and `seq[byte]` bodies
##   - `dispatchFFIEventCbor` wraps a typed payload in `EventEnvelope[T]`,
##     CBOR-encodes it, and dispatches via the event callback
##
## Tests run end-to-end against a real FFI thread (via FFIContextPool +
## sendRequestToFFIThread) so we exercise the threadvar-backed
## ffiCurrentCallbackState wiring, not just the templates in isolation.

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
  return bytes

## A request that dispatches a typed CBOR event from inside the FFI
## thread and then returns ok — so the response callback can be used to
## synchronize the test.
registerReqFFI(EmitCborEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEventCbor(
      "message_sent",
      MessageSentBody(requestId: "req-1", messageHash: "0xdeadbeef"),
    )
    return ok("emitted")

## A request that uses the lower-level `dispatchFFIEvent` with a raw
## `seq[byte]` body — the path that previously rejected non-string bodies.
registerReqFFI(EmitRawBytesEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEvent("raw_bytes"):
      @[byte 0x01, 0x02, 0x03]
    return ok("emitted")

## Setter-thread worker for the FFICallbackState race regression test.
## Hammers `setCallback` so a TSan-instrumented build can confirm
## `FFICallbackState.lock` actually serialises the cross-thread mutation
## against `snapshotCallback` reads from the FFI thread.
type SetterArgs = tuple
  ctx: ptr FFIContext[TestEvtLib]
  stop: ptr Atomic[bool]
  target: ptr CallbackData

proc setterThreadBody(args: SetterArgs) {.thread.} =
  while not args.stop[].load():
    setCallback(args.ctx[].callbackState, cast[pointer](captureCb), args.target)

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

    # Register the event callback via the same locked helper that the
    # codegen-emitted `{libname}_set_event_callback` uses.
    setCallback(ctx[].callbackState, cast[pointer](captureCb), addr evt)

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

    setCallback(ctx[].callbackState, cast[pointer](captureCb), addr evt)

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

suite "FFICallbackState concurrent access":
  ## Regression test for PR #39 review comment r3288220895 / r3289285387:
  ## `{lib}_set_event_callback` writes `callbackState.callback / .userData`
  ## from foreign caller threads while the FFI thread reads them on every
  ## dispatch. Without `FFICallbackState.lock` this is a data race.
  ##
  ## IMPORTANT: run this under ThreadSanitizer to actually validate the
  ## fix:
  ##
  ##   NIM_FFI_SAN=tsan NIM_FFI_MM=orc nimble test_sanitized
  ##
  ## A regular build will silently pass either way — the racing reads and
  ## writes are pointer-aligned, so on x86/arm64 they don't tear visibly
  ## and the loop completes. Only tsan inspects the memory model and
  ## flags the missing happens-before edge if the lock is removed.
  ## Treat a clean tsan run on this test as the load-bearing signal.
  test "concurrent setCallback writers vs dispatch reads stay race-free":
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
    setCallback(ctx[].callbackState, cast[pointer](captureCb), addr evt)

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

# ---------------------------------------------------------------------------
# Lock-during-invocation regression (issue #40 second concern)
# ---------------------------------------------------------------------------

## A foreign-thread `setCallback` must not be able to swap the callback +
## userData pair while an in-flight dispatch is mid-invocation on the
## previous pair. The dispatch templates now hold `callbackState.lock`
## for the entire snapshot + invocation, so `setCallback` blocks until
## dispatch returns.
##
## We don't use the FFI thread's request channel here because the request
## handler runs synchronously on the FFI thread before
## `reqReceivedSignal` fires — there'd be no way for the main thread to
## observe the in-flight state. Instead, a worker thread directly drives
## `dispatchFFIEvent` against a registry-of-one.

type SlowState = object
  entered: Atomic[bool]
  exited: Atomic[bool]

proc slowEventCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Signal entry, sleep briefly (the window during which the main
  ## thread must call setCallback and block), signal exit.
  let st = cast[ptr SlowState](userData)
  st[].entered.store(true)
  os.sleep(15)
  st[].exited.store(true)

type DispatcherArgs = tuple
  state: ptr FFICallbackState
  done: ptr Atomic[bool]

proc dispatcherBody(args: DispatcherArgs) {.thread.} =
  ffiCurrentCallbackState = args.state
  dispatchFFIEvent("evt"):
    "payload"
  args.done[].store(true)

suite "callbackState lock held during invocation":
  test "setCallback blocks until in-flight dispatch finishes":
    var state: FFICallbackState
    initCallbackState(state)
    defer:
      deinitCallbackState(state)

    var st: SlowState
    st.entered.store(false)
    st.exited.store(false)

    setCallback(state, cast[pointer](slowEventCb), addr st)

    var done: Atomic[bool]
    done.store(false)
    var thr: Thread[DispatcherArgs]
    createThread(thr, dispatcherBody, (addr state, addr done))

    # Wait until the worker thread is inside slowEventCb.
    for _ in 0 ..< 200:
      if st.entered.load():
        break
      os.sleep(1)
    check st.entered.load()
    check not st.exited.load()

    # Lock-during-invocation contract: setCallback blocks until the
    # dispatch's lock is released, i.e. until slowEventCb has finished.
    var other = SlowState() # dummy target; never invoked
    setCallback(state, cast[pointer](slowEventCb), addr other)
    check st.exited.load()
    joinThread(thr)
    check done.load()
