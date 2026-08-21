## foreignThreadGc + string-lifetime guarantees under both orc and refc.

import unittest2
import results
import ffi
import ./helpers

type GcTestLib = object

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
    check okString(d) == "lifetime:hello"

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
    check rawText(d) == "gc-err:test"

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
    check okString(d) == expected

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
      check okString(d) == "lifetime:" & input
      deinitCallbackData(d)
