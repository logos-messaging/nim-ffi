## End-to-end reverse-FFI tests via a real FFIContext: handlers on the FFI
## thread call `ffiReverseCall`, host impls run on the event dispatch thread and
## answer through `submitReverseReply` — inline, from a foreign thread, late, or
## never (timeout / recycle).

import std/[locks, os, strutils]
import unittest2
import results
import ffi

type TestRevLib = object

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
  if retCode != RET_STALE_WARN:
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

proc callbackMsg(d: var CallbackData): string =
  result = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr result[0], addr d.msg[0], d.msgLen)

template withPool(ctxIdent: untyped, body: untyped) =
  var pool: FFIContextPool[TestRevLib]
  let ctxIdent = pool.createFFIContext().valueOr:
    check false
    return
  defer:
    discard pool.destroyFFIContext(ctxIdent)
  body

## Handlers: each drives one scenario; the reverse name and deadline are fixed.

registerReqFFI(CallEchoRequest, lib: ptr TestRevLib):
  proc(): Future[Result[string, string]] {.async.} =
    let r = await ffiReverseCall("echo", @[byte 1, 2, 3], 2000)
    if r.isErr():
      return err(r.error)
    if r.value != @[byte 1, 2, 3]:
      return err("echo payload mismatch")
    return ok("echoed")

registerReqFFI(CallParkedRequest, lib: ptr TestRevLib):
  proc(): Future[Result[string, string]] {.async.} =
    let r = await ffiReverseCall("parked", @[byte 42], 5000)
    if r.isErr():
      return err(r.error)
    if r.value != @[byte 9]:
      return err("parked payload mismatch")
    return ok("answered off-thread")

registerReqFFI(CallMissingRequest, lib: ptr TestRevLib):
  proc(): Future[Result[string, string]] {.async.} =
    let r = await ffiReverseCall("nobody", @[], 500)
    if r.isErr():
      return err(r.error)
    return ok("unexpected success")

registerReqFFI(CallSilentRequest, lib: ptr TestRevLib):
  proc(): Future[Result[string, string]] {.async.} =
    let r = await ffiReverseCall("silent", @[], 200)
    if r.isErr():
      return err(r.error)
    return ok("unexpected success")

registerReqFFI(CallAbandonedRequest, lib: ptr TestRevLib):
  proc(): Future[Result[string, string]] {.async.} =
    let r = await ffiReverseCall("abandoned", @[], 30000)
    if r.isErr():
      return err(r.error)
    return ok("unexpected success")

## Host implementations (run on the event dispatch thread).

proc echoImpl(
    callId: uint64, argsCbor: ptr UncheckedArray[byte], argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## Inline reply from within the invocation, on the event thread.
  let ctx = cast[ptr FFIContext[TestRevLib]](userData)
  discard submitReverseReply(ctx, callId, RET_OK, argsCbor, int(argsLen))

type ParkBox = object
  lock: Lock
  cond: Cond
  got: bool
  callId: uint64

proc parkImpl(
    callId: uint64, argsCbor: ptr UncheckedArray[byte], argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## No reply here: hands the call id to the test thread, which answers later.
  let box = cast[ptr ParkBox](userData)
  acquire(box[].lock)
  box[].callId = callId
  box[].got = true
  signal(box[].cond)
  release(box[].lock)

proc silentImpl(
    callId: uint64, argsCbor: ptr UncheckedArray[byte], argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  discard # never answers; the caller's deadline must fire

type SlowBox = object
  entered: Atomic[bool]
  exited: Atomic[bool]

proc slowImpl(
    callId: uint64, argsCbor: ptr UncheckedArray[byte], argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  let box = cast[ptr SlowBox](userData)
  box[].entered.store(true)
  os.sleep(60)
  box[].exited.store(true)

proc waitParked(box: var ParkBox): uint64 =
  acquire(box.lock)
  while not box.got:
    wait(box.cond, box.lock)
  result = box.callId
  release(box.lock)

suite "reverse call roundtrip":
  test "impl replying inline on the event thread completes the handler":
    setupCallbackData(rsp)
    withPool(ctx):
      ctx[].reverse.setImpl("echo", echoImpl, ctx)
      check sendRequestToFFIThread(ctx, CallEchoRequest.ffiNewReq(captureCb, addr rsp))
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_OK
      check "echoed" in callbackMsg(rsp)

  test "reply submitted later from a foreign thread completes the handler":
    setupCallbackData(rsp)
    withPool(ctx):
      var box: ParkBox
      box.lock.initLock()
      box.cond.initCond()
      defer:
        box.cond.deinitCond()
        box.lock.deinitLock()

      ctx[].reverse.setImpl("parked", parkImpl, addr box)
      check sendRequestToFFIThread(
        ctx, CallParkedRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()

      let callId = waitParked(box)
      os.sleep(20) # the handler is genuinely parked when the reply lands
      var payload = [byte 9]
      # This thread is neither the FFI nor the event thread: the any-thread path.
      check submitReverseReply(ctx, callId, RET_OK, addr payload[0], 1) ==
        REVERSE_ACCEPTED

      waitCallback(rsp)
      check rsp.retCode == RET_OK
      check "answered off-thread" in callbackMsg(rsp)

suite "reverse call failure modes":
  test "unfulfilled interface fails fast":
    setupCallbackData(rsp)
    withPool(ctx):
      check sendRequestToFFIThread(
        ctx, CallMissingRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_ERR
      check "no host implementation" in callbackMsg(rsp)

  test "an impl that never answers trips the call deadline":
    setupCallbackData(rsp)
    withPool(ctx):
      ctx[].reverse.setImpl("silent", silentImpl, nil)
      check sendRequestToFFIThread(
        ctx, CallSilentRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_ERR
      check "timed out" in callbackMsg(rsp)

suite "registration semantics":
  test "unregistering blocks until the in-flight invocation returns":
    setupCallbackData(rsp)
    withPool(ctx):
      var box: SlowBox
      box.entered.store(false)
      box.exited.store(false)
      ctx[].reverse.setImpl("silent", slowImpl, addr box)
      check sendRequestToFFIThread(
        ctx, CallSilentRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()

      for _ in 0 ..< 500:
        if box.entered.load():
          break
        os.sleep(1)
      check box.entered.load()
      check not box.exited.load()

      # Blocks until slowImpl returns, so its userData may be freed right after.
      ctx[].reverse.setImpl("silent", nil, nil)
      check box.exited.load()

      waitCallback(rsp) # the call itself then dies on its deadline
      check rsp.retCode == RET_ERR

suite "teardown with a reverse call in flight":
  test "recycle fails the parked call instead of waiting out its deadline":
    ## The handler's deadline (30 s) is far beyond RecycleWaitTimeout: destroy
    ## succeeding in time proves failPendingReverse unparked the handler.
    setupCallbackData(rsp)
    var pool: FFIContextPool[TestRevLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return

    var box: ParkBox
    box.lock.initLock()
    box.cond.initCond()
    defer:
      box.cond.deinitCond()
      box.lock.deinitLock()

    ctx[].reverse.setImpl("abandoned", parkImpl, addr box)
    check sendRequestToFFIThread(
      ctx, CallAbandonedRequest.ffiNewReq(captureCb, addr rsp)
    )
      .isOk()
    discard waitParked(box)

    check pool.destroyFFIContext(ctx).isOk()
    waitCallback(rsp)
    check rsp.retCode == RET_ERR
    check "abandoned" in callbackMsg(rsp)
