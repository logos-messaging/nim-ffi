## foreignThreadGc + string-lifetime guarantees under both orc and refc.

import std/locks
import unittest2
import results
import ffi

type GcTestLib = object

type CallbackData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  msg: array[1024, char]
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
  var msg = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr msg[0], addr d.msg[0], d.msgLen)
  return msg

proc callbackBytes(d: var CallbackData): seq[byte] =
  var bytes = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr bytes[0], addr d.msg[0], d.msgLen)
  return bytes

proc callbackOkString(d: var CallbackData): string =
  ## Decodes the CBOR success payload as a string, asserting the request succeeded.
  doAssert d.retCode == RET_OK,
    "callbackOkString called on non-OK retCode " & $d.retCode & " (msg=" & callbackMsg(
      d
    ) & ")"
  cborDecode(callbackBytes(d), string).valueOr:
    return ""

# Non-literal result exercises the resStr lifetime binding in handleRes.
registerReqFFI(StringLifetimeRequest, lib: ptr GcTestLib):
  proc(input: cstring): Future[Result[string, string]] {.async.} =
    let prefix = "lifetime:"
    let suffix = $input
    return ok(prefix & suffix)

registerReqFFI(LargeStringRequest, lib: ptr GcTestLib):
  proc(): Future[Result[string, string]] {.async.} =
    var s = newString(512)
    for i in 0 ..< 512:
      s[i] = char(ord('a') + (i mod 26))
    return ok(s)

registerReqFFI(GcErrRequest, lib: ptr GcTestLib):
  proc(input: cstring): Future[Result[string, string]] {.async.} =
    return err("gc-err:" & $input)

suite "foreignThreadGc template":
  test "body executes under current --mm":
    var executed = false
    foreignThreadGc:
      executed = true
    check executed

  test "body executes exactly once":
    var count = 0
    foreignThreadGc:
      inc count
    check count == 1

suite "GC safety - string lifetime across thread boundary":
  test "ok string result remains valid when callback fires":
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(
      ctx, StringLifetimeRequest.ffiNewReq(testCallback, addr d, "hello".cstring)
    )
      .isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check callbackOkString(d) == "lifetime:hello"

  test "error string lifetime across thread boundary":
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(
      ctx, GcErrRequest.ffiNewReq(testCallback, addr d, "test".cstring)
    )
      .isOk()
    waitCallback(d)
    check d.retCode == RET_ERR
    check callbackMsg(d) == "gc-err:test"

  test "large string result is delivered without corruption":
    var expected = newString(512)
    for i in 0 ..< 512:
      expected[i] = char(ord('a') + (i mod 26))

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(
      ctx, LargeStringRequest.ffiNewReq(testCallback, addr d)
    )
      .isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check callbackOkString(d) == expected

suite "GC stability - repeated requests":
  test "20 sequential requests without GC corruption":
    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    for i in 1 .. 20:
      var d: CallbackData
      initCallbackData(d)
      let input = "iter" & $i
      check sendRequestToFFIThread(
        ctx, StringLifetimeRequest.ffiNewReq(testCallback, addr d, input.cstring)
      )
        .isOk()
      waitCallback(d)
      check d.retCode == RET_OK
      check callbackOkString(d) == "lifetime:" & input
      deinitCallbackData(d)
