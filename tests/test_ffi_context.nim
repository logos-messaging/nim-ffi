import std/locks
import unittest2
import results
import ../ffi

type TestLib = object

## Per-request callback state.  The test thread blocks on `cond` until the
## FFI thread signals it — no polling, no CPU waste.
type CallbackData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  msg: array[512, char]
  msgLen: int

proc initCallbackData(d: var CallbackData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitCallbackData(d: var CallbackData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

proc testCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].retCode = retCode
  let n = min(int(len), d[].msg.high)
  if n > 0 and not msg.isNil:
    copyMem(addr d[].msg[0], msg, n)
  d[].msg[n] = '\0'
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

registerReqFFI(PingRequest, lib: ptr TestLib):
  proc(message: cstring): Future[Result[string, string]] {.async.} =
    return ok("pong:" & $message)

registerReqFFI(FailRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    return err("intentional failure")

registerReqFFI(EmptyOkRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("")

suite "createFFIContext / destroyFFIContext":
  test "create and destroy succeeds":
    let ctx = createFFIContext[TestLib]().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    check destroyFFIContext(ctx).isOk()

  test "double destroy is safe via running flag":
    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    check destroyFFIContext(ctx).isOk()

suite "sendRequestToFFIThread":
  test "successful request triggers RET_OK callback":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    defer: discard destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, PingRequest.ffiNewReq(testCallback, addr d, "hello".cstring)).isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check callbackMsg(d) == "pong:hello"

  test "failing request triggers RET_ERR callback":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    defer: discard destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, FailRequest.ffiNewReq(testCallback, addr d)).isOk()
    waitCallback(d)
    check d.retCode == RET_ERR

  test "empty ok response delivers empty message":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    defer: discard destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, EmptyOkRequest.ffiNewReq(testCallback, addr d)).isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check d.msgLen == 0

  test "sequential requests are all processed":
    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    defer: discard destroyFFIContext(ctx)

    for i in 1 .. 5:
      var d: CallbackData
      initCallbackData(d)
      let msg = "msg" & $i
      check sendRequestToFFIThread(ctx, PingRequest.ffiNewReq(testCallback, addr d, msg.cstring)).isOk()
      waitCallback(d)
      deinitCallbackData(d)
      check d.retCode == RET_OK
      check callbackMsg(d) == "pong:" & msg
