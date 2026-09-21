import std/[atomics, os, strutils]
import unittest2
import results
import ffi
import ./helpers

type TestLib = object

var gHandlerEntered: Atomic[bool]
var gHandlerRelease: Atomic[bool]

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
  EchoRequest.ffiNewReq(payload)

suite "request ingress limits":
  test "a full ingress queue rejects the submit, and drains back to accepting":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      assert false, "createFFIContext failed: " & $error
      return
    defer:
      gHandlerRelease.store(true)
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, BlockRequest.ffiNewReq()).isOk()
    check spinUntil(gHandlerEntered.load())

    for _ in 0 ..< RequestQueueDepth:
      check sendRequestToFFIThread(ctx, echoReq("queued")).isOk()

    var refusedId = 0'u64
    check submitRequest(
      ctx, echoReq("one too many"), ctx.currentGeneration(), addr refusedId
    ) == RET_QUEUE_FULL
    check "request queue full" in $lastError()
    check refusedId == 0

    gHandlerRelease.store(true)
    # One reply per accepted request, none for the refused one.
    for _ in 0 ..< RequestQueueDepth + 1:
      let reply = nextMsg(ctx)
      check reply.kind == MsgReply
      check reply.retCode == RET_OK
    check nextMsg(ctx, 100).ret == RET_TIMEOUT
    check call(ctx, echoReq("after the drain")).okString() == "after the drain"

  test "a payload over the cap is rejected at the submit":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      assert false, "createFFIContext failed: " & $error
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var refusedId = 0'u64
    check submitRequest(
      ctx,
      echoReq(repeat('x', MaxRequestPayloadBytes + 1)),
      ctx.currentGeneration(),
      addr refusedId,
    ) == RET_TOO_LARGE
    check refusedId == 0
    check "exceeds the " & $MaxRequestPayloadBytes & " byte cap" in $lastError()
    check nextMsg(ctx, 100).ret == RET_TIMEOUT

    check call(ctx, echoReq("small")).okString() == "small"
