## Verifies correct behaviour under both --mm:orc and --mm:refc.
##
## The foreignThreadGc template must set up / tear down the GC for foreign
## threads under refc and be a no-op under orc/arc.  The handleRes proc
## holds a string local long enough for the callback to read its cstring
## -- these tests catch regressions in that lifetime guarantee.

import std/locks
import unittest2
import results
import ../ffi

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
  result = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr result[0], addr d.msg[0], d.msgLen)

# Concatenates GC-allocated strings so the result is not a string literal;
# exercises the resStr lifetime binding inside handleRes.
registerReqFFI(StringLifetimeRequest, lib: ptr GcTestLib):
  proc(input: cstring): Future[Result[string, string]] {.async.} =
    let prefix = "lifetime:"
    let suffix = $input
    return ok(prefix & suffix)

# Returns 512 bytes of repeating a-z to stress GC with a moderately large
# allocation that must survive the cross-thread callback.
registerReqFFI(LargeStringRequest, lib: ptr GcTestLib):
  proc(): Future[Result[string, string]] {.async.} =
    var s = newString(512)
    for i in 0 ..< 512:
      s[i] = char(ord('a') + (i mod 26))
    return ok(s)

# Error path: the error string must be alive when the callback fires.
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
    defer: deinitCallbackData(d)

    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    defer: discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(
      ctx, StringLifetimeRequest.ffiNewReq(testCallback, addr d, "hello".cstring)
    ).isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check callbackMsg(d) == "lifetime:hello"

  test "error string lifetime across thread boundary":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer: discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(
      ctx, GcErrRequest.ffiNewReq(testCallback, addr d, "test".cstring)
    ).isOk()
    waitCallback(d)
    check d.retCode == RET_ERR
    check callbackMsg(d) == "gc-err:test"

  test "large string result is delivered without corruption":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer: discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(
      ctx, LargeStringRequest.ffiNewReq(testCallback, addr d)
    ).isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check d.msgLen == 512
    check d.msg[0] == 'a'
    check d.msg[25] == 'z'
    check d.msg[26] == 'a'

suite "GC stability - repeated requests":
  test "20 sequential requests without GC corruption":
    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer: discard pool.destroyFFIContext(ctx)

    for i in 1 .. 20:
      var d: CallbackData
      initCallbackData(d)
      let input = "iter" & $i
      check sendRequestToFFIThread(
        ctx, StringLifetimeRequest.ffiNewReq(testCallback, addr d, input.cstring)
      ).isOk()
      waitCallback(d)
      deinitCallbackData(d)
      check d.retCode == RET_OK
      check callbackMsg(d) == "lifetime:" & input
