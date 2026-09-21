## String-lifetime guarantees of a reply under both orc and refc.

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

suite "GC safety - string lifetime across thread boundary":
  test "ok string result remains valid when the host polls it":
    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check call(ctx, StringLifetimeRequest.ffiNewReq("hello".cstring)).okString() ==
      "lifetime:hello"

  test "error string lifetime across thread boundary":
    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    let reply = call(ctx, GcErrRequest.ffiNewReq("test".cstring))
    check reply.retCode == RET_ERR
    check reply.text() == "gc-err:test"

  test "large string result is delivered without corruption":
    var expected = newString(512)
    for i in 0 ..< 512:
      expected[i] = char(ord('a') + (i mod 26))

    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check call(ctx, LargeStringRequest.ffiNewReq()).okString() == expected

suite "GC stability - repeated requests":
  test "20 sequential requests without GC corruption":
    var pool: FFIContextPool[GcTestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    for i in 1 .. 20:
      let input = "iter" & $i
      check call(ctx, StringLifetimeRequest.ffiNewReq(input.cstring)).okString() ==
        "lifetime:" & input
