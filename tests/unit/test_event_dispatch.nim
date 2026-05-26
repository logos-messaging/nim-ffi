## Tests for the CBOR-style FFI event dispatch path:
##   - `dispatchFFIEvent` accepts both `string` and `seq[byte]` bodies
##   - `dispatchFFIEventCbor` wraps a typed payload in `EventEnvelope[T]`,
##     CBOR-encodes it, and dispatches via the event callback
##
## Tests run end-to-end against a real FFI thread (via FFIContextPool +
## sendRequestToFFIThread) so we exercise the threadvar-backed
## ffiCurrentEventRegistry wiring, not just the templates in isolation.

import std/[locks]
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

## Setter-thread worker for the registry race regression test.
## Each iteration adds then immediately removes a wildcard listener so a
## TSan-instrumented build can confirm `FFIEventRegistry.lock` serialises
## the cross-thread mutation against dispatch-time `snapshotListeners`
## reads from the FFI thread.
type SetterArgs = tuple
  ctx: ptr FFIContext[TestEvtLib]
  stop: ptr Atomic[bool]
  target: ptr CallbackData

proc setterThreadBody(args: SetterArgs) {.thread.} =
  while not args.stop[].load():
    let id = addEventListener(
      args.ctx[].eventRegistry, WildcardEventName, captureCb, args.target
    )
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

    # Register the event callback through the multi-listener registry.
    discard addEventListener(
      ctx[].eventRegistry, WildcardEventName, captureCb, addr evt
    )

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

    discard addEventListener(
      ctx[].eventRegistry, WildcardEventName, captureCb, addr evt
    )

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
  ## Skipped under `--mm:refc`: each setter thread grows / shrinks
  ## `reg.wildcard` (a `seq[FFIEventListener]`) via `addEventListener`,
  ## and refc's per-thread GC heap ownership makes cross-thread seq
  ## buffer reallocation unsafe even when the surrounding lock is held —
  ## a buffer allocated by one thread can end up freed by another. ORC
  ## (and the FFI thread + tsan combo this test was written for) does
  ## not have that limitation. Production foreign-side code typically
  ## registers listeners from a single thread, which is safe under both
  ## memory managers; this test is the stress case that isn't.
  suite "FFIEventRegistry concurrent access":
    ## Regression test for PR #39 review comment r3288220895 / r3289285387:
    ## foreign caller threads mutate the registry's wildcard list while
    ## the FFI thread reads it on every dispatch. Without
    ## `FFIEventRegistry.lock` this is a data race.
    ##
    ## IMPORTANT: run this under ThreadSanitizer to actually validate the
    ## fix:
    ##
    ##   NIM_FFI_SAN=tsan NIM_FFI_MM=orc nimble test_sanitized
    ##
    ## A regular build will silently pass either way — the racing reads
    ## and writes are pointer-aligned, so on x86/arm64 they don't tear
    ## visibly and the loop completes. Only tsan inspects the memory
    ## model and flags the missing happens-before edge if the lock is
    ## removed. Treat a clean tsan run on this test as the load-bearing
    ## signal.
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

      # Seed an initial listener so the FFI thread's first dispatch has a
      # target. The setter threads will then repeatedly add/remove their
      # own listeners — what matters is the cross-thread mutation racing
      # the FFI thread's read.
      discard addEventListener(
        ctx[].eventRegistry, WildcardEventName, captureCb, addr evt
      )

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
