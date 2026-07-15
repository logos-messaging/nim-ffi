## End-to-end tests for `dispatchFFIEvent` / `dispatchFFIEventCbor` via a real FFIContext.

import std/[locks, os]
import unittest2
import results
import ffi

type TestEvtLib = object

type MessageSentBody* {.ffi.} = object
  requestId*: string
  messageHash*: string

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

proc resetCalled(d: var CallbackData) =
  acquire(d.lock)
  d.called = false
  release(d.lock)

proc callbackBytes(d: var CallbackData): seq[byte] =
  var bytes = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr bytes[0], addr d.msg[0], d.msgLen)
  bytes

template withPool(ctxIdent: untyped, body: untyped) =
  var pool: FFIContextPool[TestEvtLib]
  let ctxIdent = pool.createFFIContext().valueOr:
    check false
    return
  defer:
    discard pool.destroyFFIContext(ctxIdent)
  body

registerReqFFI(EmitCborEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEventCbor(
      "message_sent", MessageSentBody(requestId: "req-1", messageHash: "0xdeadbeef")
    )
    return ok("emitted")

registerReqFFI(EmitRawBytesEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEvent("raw_bytes"):
      @[byte 0x01, 0x02, 0x03]
    return ok("emitted")

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
    # LIFO defer order: pool destroy joins the event thread before mutex teardown.
    setupCallbackData(evt)
    setupCallbackData(rsp)

    withPool(ctx):
      discard addEventListener(ctx[].eventRegistry, "message_sent", captureCb, addr evt)

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
    setupCallbackData(evt)
    setupCallbackData(rsp)

    withPool(ctx):
      discard addEventListener(ctx[].eventRegistry, "raw_bytes", captureCb, addr evt)

      check sendRequestToFFIThread(
        ctx, EmitRawBytesEventRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)
      waitCallback(evt)

      check evt.retCode == RET_OK
      check callbackBytes(evt) == @[byte 0x01, 0x02, 0x03]

when not defined(gcRefc):
  ## Skipped under refc: cross-thread listener-seq growth is unsafe with refc's GC.
  suite "FFIEventRegistry concurrent access":
    ## Regression for PR #39; validate with NIM_FFI_SAN=tsan NIM_FFI_MM=orc.
    test "concurrent add/remove writers vs dispatch reads stay race-free":
      setupCallbackData(evt)
      setupCallbackData(rsp)

      withPool(ctx):
        discard
          addEventListener(ctx[].eventRegistry, "message_sent", captureCb, addr evt)

        const NumSetterThreads = 4
        const NumDispatchIters = 200

        var stop: Atomic[bool]
        stop.store(false)
        var setters: array[NumSetterThreads, Thread[SetterArgs]]
        for i in 0 ..< NumSetterThreads:
          createThread(setters[i], setterThreadBody, (ctx, addr stop, addr evt))

        for _ in 0 ..< NumDispatchIters:
          resetCalled(rsp)
          check sendRequestToFFIThread(
            ctx, EmitCborEventRequest.ffiNewReq(captureCb, addr rsp)
          )
            .isOk()
          waitCallback(rsp)

        stop.store(true)
        for i in 0 ..< NumSetterThreads:
          joinThread(setters[i])

        check evt.called

type SlowState = object
  entered: Atomic[bool]
  exited: Atomic[bool]

proc slowEventCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let st = cast[ptr SlowState](userData)
  st[].entered.store(true)
  os.sleep(60)
  st[].exited.store(true)

suite "registry lock held during invocation":
  test "removeEventListener blocks until in-flight dispatch finishes":
    setupCallbackData(rsp)

    withPool(ctx):
      var st: SlowState
      st.entered.store(false)
      st.exited.store(false)

      let id =
        addEventListener(ctx[].eventRegistry, "message_sent", slowEventCb, addr st)
      check id != 0'u64

      check sendRequestToFFIThread(
        ctx, EmitCborEventRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)

      for _ in 0 ..< 500:
        if st.entered.load():
          break
        os.sleep(1)
      check st.entered.load()
      check not st.exited.load()

      # remove blocks until the in-flight dispatch finishes (exited=true by then).
      check removeEventListener(ctx[].eventRegistry, id)
      check st.exited.load()

suite "liveness events":
  ## Liveness signals dispatch directly, bypassing the (maybe wedged) queue.
  test "onNotResponding delivers EventEnvelope[NotRespondingEvent] to subscribers":
    setupCallbackData(evt)

    withPool(ctx):
      discard addEventListener(
        ctx[].eventRegistry, NotRespondingEventName, captureCb, addr evt
      )

      onNotResponding(ctx)

      waitCallback(evt)
      check evt.retCode == RET_OK
      let decoded = cborDecode(callbackBytes(evt), EventEnvelope[NotRespondingEvent])
      check decoded.isOk()
      check decoded.value.eventType == NotRespondingEventName

  test "onResponding delivers EventEnvelope[RespondingEvent] to subscribers":
    setupCallbackData(evt)

    withPool(ctx):
      discard
        addEventListener(ctx[].eventRegistry, RespondingEventName, captureCb, addr evt)

      onResponding(ctx)

      waitCallback(evt)
      check evt.retCode == RET_OK
      let decoded = cborDecode(callbackBytes(evt), EventEnvelope[RespondingEvent])
      check decoded.isOk()
      check decoded.value.eventType == RespondingEventName

  test "liveness events with no subscriber are a no-op":
    withPool(ctx):
      onNotResponding(ctx)
      onResponding(ctx)

suite "event thread drains queued events":
  test "enqueued event is delivered to subscriber within a tick":
    setupCallbackData(evt)

    withPool(ctx):
      const QueuedEvtName = "queued_evt"
      discard addEventListener(ctx[].eventRegistry, QueuedEvtName, captureCb, addr evt)

      let payload = @[byte 0xDE, 0xAD, 0xBE, 0xEF]
      check tryEnqueueEvent(
        ctx[].eventQueue, cstring(QueuedEvtName), unsafeAddr payload[0], payload.len
      )

      waitCallback(evt)
      check evt.retCode == RET_OK
      check callbackBytes(evt) == payload

suite "oversize payload falls back to heap":
  ## Payloads over MaxEventPayloadBytes take the c_malloc'd heap fallback.
  test "payload above the slab budget still delivers intact":
    setupCallbackData(evt)

    withPool(ctx):
      const OversizeEvtName = "oversize_evt"
      discard
        addEventListener(ctx[].eventRegistry, OversizeEvtName, captureCb, addr evt)

      var payload = newSeq[byte](MaxEventPayloadBytes + 64)
      for i in 0 ..< payload.len:
        payload[i] = byte(i and 0xFF)
      check payload.len > MaxEventPayloadBytes
      check tryEnqueueEvent(
        ctx[].eventQueue, cstring(OversizeEvtName), unsafeAddr payload[0], payload.len
      )

      waitCallback(evt)
      check evt.retCode == RET_OK
      let n = min(payload.len, 1024) # captureCb caps at its 1024-byte buffer
      check callbackBytes(evt) == payload[0 ..< n]

suite "oversize event name falls back to heap":
  ## A name over MaxEventNameBytes takes the heap fallback and still routes.
  test "name above the name-slab budget still delivers to the right listener":
    setupCallbackData(evt)

    withPool(ctx):
      const LongEvtName =
        "oversize_event_name_that_is_deliberately_much_longer_than_the_name_slab_budget"
      check LongEvtName.len > MaxEventNameBytes
      discard addEventListener(ctx[].eventRegistry, LongEvtName, captureCb, addr evt)

      let payload = @[byte 0x11, 0x22, 0x33]
      check tryEnqueueEvent(
        ctx[].eventQueue, cstring(LongEvtName), unsafeAddr payload[0], payload.len
      )

      waitCallback(evt)
      check evt.retCode == RET_OK
      check callbackBytes(evt) == payload
