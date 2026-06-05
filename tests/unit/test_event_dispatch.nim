## End-to-end tests for `dispatchFFIEvent` / `dispatchFFIEventCbor`,
## driven through a real `FFIContext` so the threadvar wiring is exercised.

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
  ## Sets up pool + ctx, runs body, destroys on exit.
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
      "message_sent",
      MessageSentBody(requestId: "req-1", messageHash: "0xdeadbeef"),
    )
    return ok("emitted")

registerReqFFI(EmitRawBytesEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEvent("raw_bytes"):
      @[byte 0x01, 0x02, 0x03]
    return ok("emitted")

# Add/remove worker for the registry-race regression test.
type SetterArgs = tuple
  ctx: ptr FFIContext[TestEvtLib]
  stop: ptr Atomic[bool]
  target: ptr CallbackData

proc setterThreadBody(args: SetterArgs) {.thread.} =
  while not args.stop[].load():
    let id = addEventListener(
      args.ctx[].eventRegistry, "message_sent", captureCb, args.target
    )
    discard removeEventListener(args.ctx[].eventRegistry, id)

suite "dispatchFFIEventCbor":
  test "delivers EventEnvelope-shaped CBOR payload to event callback":
    # CallbackData defers declared first run last (LIFO), AFTER pool destroy
    # joins the event thread — otherwise TSan flags captureCb on a destroyed mutex.
    setupCallbackData(evt)
    setupCallbackData(rsp)

    withPool(ctx):
      discard addEventListener(
        ctx[].eventRegistry, "message_sent", captureCb, addr evt
      )

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
      discard addEventListener(
        ctx[].eventRegistry, "raw_bytes", captureCb, addr evt
      )

      check sendRequestToFFIThread(
        ctx, EmitRawBytesEventRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)
      waitCallback(evt)

      check evt.retCode == RET_OK
      check callbackBytes(evt) == @[byte 0x01, 0x02, 0x03]

when not defined(gcRefc):
  ## Skipped under refc: setter threads grow/shrink the per-event listener
  ## seq, and refc's per-thread GC heap makes that unsafe cross-thread.
  suite "FFIEventRegistry concurrent access":
    ## Regression for PR #39 (r3288220895 / r3289285387).
    ## Validate with: NIM_FFI_SAN=tsan NIM_FFI_MM=orc nimble test_sanitized
    test "concurrent add/remove writers vs dispatch reads stay race-free":
      setupCallbackData(evt)
      setupCallbackData(rsp)

      withPool(ctx):
        # Seed an initial listener so the first dispatch has a target.
        discard addEventListener(
          ctx[].eventRegistry, "message_sent", captureCb, addr evt
        )

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

      let id = addEventListener(
        ctx[].eventRegistry, "message_sent", slowEventCb, addr st
      )
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

      # Lock-during-invocation: remove blocks until dispatch finishes,
      # by which time slowEventCb has set exited=true.
      check removeEventListener(ctx[].eventRegistry, id)
      check st.exited.load()
