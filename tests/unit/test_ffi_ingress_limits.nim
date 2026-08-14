import std/[atomics, os, strutils]
import unittest2
import results
import ffi

type TestLib = object

var gHandlerEntered: Atomic[bool]
var gHandlerRelease: Atomic[bool]
var gAnswered: Atomic[int]

proc countingCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  if retCode == RET_STALE_WARN:
    return
  discard gAnswered.fetchAdd(1)

template spinUntil(cond: untyped): bool =
  block:
    var waitedMs = 0
    while not (cond) and waitedMs < 5000:
      os.sleep(1)
      inc waitedMs
    cond

registerReqFFI(BlockRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    # Blocks the FFI thread outright, so every later submit stays queued.
    gHandlerEntered.store(true)
    while not gHandlerRelease.load():
      os.sleep(1)
    return ok("released")

registerReqFFI(EchoRequest, lib: ptr TestLib):
  proc(message: string): Future[Result[string, string]] {.async.} =
    return ok(message)

proc echoReq(payload: string): ptr FFIThreadRequest =
  EchoRequest.ffiNewReq(countingCallback, nil, payload)

suite "request ingress limits":
  test "a full ingress queue rejects the submit, and drains back to accepting":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      assert false, "createFFIContext failed: " & $error
      return
    defer:
      gHandlerRelease.store(true)
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, BlockRequest.ffiNewReq(countingCallback, nil))
      .isOk()
    check spinUntil(gHandlerEntered.load())

    for _ in 0 ..< RequestQueueDepth:
      check sendRequestToFFIThread(ctx, echoReq("queued")).isOk()

    let rejected = sendRequestToFFIThread(ctx, echoReq("one too many"))
    check rejected.isErr() and "request queue full" in rejected.error

    gHandlerRelease.store(true)
    check spinUntil(gAnswered.load() == RequestQueueDepth + 1)
    check sendRequestToFFIThread(ctx, echoReq("after the drain")).isOk()

  test "a payload over the cap is rejected at the submit":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      assert false, "createFFIContext failed: " & $error
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    let oversized =
      sendRequestToFFIThread(ctx, echoReq(repeat('x', MaxRequestPayloadBytes + 1)))
    check oversized.isErr() and
      "exceeds the " & $MaxRequestPayloadBytes & " byte cap" in oversized.error

    check sendRequestToFFIThread(ctx, echoReq("small")).isOk()
