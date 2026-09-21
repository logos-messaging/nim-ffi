## Replies are never dropped, so what bounds a host that submits and never polls
## is the cap on unanswered requests. The sibling .cfg sets it to 8.

import std/atomics
import unittest2
import results
import ffi
import ./helpers

type CapLib = object

registerReqFFI(Ping, lib: ptr CapLib):
  proc(n: int): Future[Result[int, string]] {.async.} =
    return ok(n)

# Module-level, as declareLibrary emits it: a recycled slot keeps its threads.
var gPool: FFIContextPool[CapLib]

proc submit(ctx: ptr FFIContext[CapLib], n: int, reqId: var uint64): cint =
  return submitRequest(ctx, Ping.ffiNewReq(n), ctx.currentGeneration(), addr reqId)

suite "outstanding request cap":
  test "the cap is what the .cfg says":
    check MaxOutstandingRequests == 8

  test "the submit over the cap is refused, and accepted again once replies are polled":
    let ctx = gPool.createFFIContext().valueOr:
      check false
      return
    defer:
      check gPool.recycleFFIContext(ctx).isOk()

    var accepted: seq[uint64]
    for i in 0 ..< MaxOutstandingRequests:
      var reqId: uint64
      check submit(ctx, i, reqId) == RET_OK
      accepted.add(reqId)

    # Answered is not collected: the replies wait, so the requests still count.
    check waitReplyQueued(ctx)
    var refusedId = 0'u64
    check submit(ctx, 99, refusedId) == RET_QUEUE_FULL
    check refusedId == 0
    check $lastError() ==
      $MaxOutstandingRequests & " requests wait for the host to poll their replies"
    check ctx[].outbound.outstanding.load() == MaxOutstandingRequests

    # Every accepted request is answered, in order; the refused one never is.
    for i in 0 ..< MaxOutstandingRequests:
      let reply = pollMsg(ctx)
      check reply.kind == MsgReply
      check reply.id == accepted[i]
      check cborDecode(reply.payload, int).value == i
    check pollMsg(ctx, 100).ret == RET_TIMEOUT
    check ctx[].outbound.outstanding.load() == 0

    for i in 0 ..< MaxOutstandingRequests:
      var reqId: uint64
      check submit(ctx, i, reqId) == RET_OK
      check reqId > accepted[^1]
    check submit(ctx, 99, refusedId) == RET_QUEUE_FULL

  test "the unpolled replies of a past owner do not count against the next one":
    let first = gPool.createFFIContext().valueOr:
      check false
      return
    var reqId: uint64
    for i in 0 ..< MaxOutstandingRequests:
      check submit(first, i, reqId) == RET_OK
    check submit(first, 99, reqId) == RET_QUEUE_FULL
    check gPool.recycleFFIContext(first).isOk()
    waitSlotFree(first)

    let second = gPool.createFFIContext().valueOr:
      check false
      return
    defer:
      check gPool.recycleFFIContext(second).isOk()
    # Lowest free slot wins, so a fresh slot here would prove nothing.
    check second == first
    for i in 0 ..< MaxOutstandingRequests:
      check submit(second, i, reqId) == RET_OK
    check submit(second, 99, reqId) == RET_QUEUE_FULL
