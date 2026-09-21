## What a poller sees when its context ends: a blocked poll wakes with
## `RET_CLOSED`, the old token stops resolving, and the next owner of the slot
## gets none of the old messages. Validate with NIM_FFI_SAN=tsan NIM_FFI_MM=orc.

import std/[atomics, os]
import unittest2
import results
import ffi
import ./helpers

type TestCloseLib = object

type LatchPayload* {.ffi.} = object
  iter*: int

startWatchdog(120_000, "a poll did not wake when its context ended")

registerReqFFI(BurstEmit, lib: ptr TestCloseLib):
  proc(count: int): Future[Result[string, string]] {.async.} =
    for i in 0 ..< count:
      dispatchFFIEventCbor("latch", LatchPayload(iter: i))
    return ok("bursted")

proc emit(ctx: ptr FFIContext[TestCloseLib], count: int) =
  setupCallbackData(rsp)
  doAssert sendRequestToFFIThread(
    ctx, BurstEmit.ffiNewReq(testCallback, addr rsp, count)
  )
    .isOk()
  waitCallback(rsp)

type BlockedPoll = object
  ctx: ptr FFIContext[TestCloseLib]
  generation: uint
  entered: Atomic[bool]
  ret: Atomic[int]
  kind: Atomic[uint32]

proc blockedPollBody(args: ptr BlockedPoll) {.thread.} =
  var msg: ptr NimFfiMsg
  args.entered.store(true)
  args.ret.store(int(pollContext(args.ctx, args.generation, -1, addr msg)))
  if not msg.isNil():
    args.kind.store(msg.kind)

template withBlockedPoller(ctx: untyped, blocked: untyped, body: untyped) =
  var blocked = BlockedPoll(ctx: ctx, generation: ctx.currentGeneration())
  blocked.ret.store(-1)
  var th: Thread[ptr BlockedPoll]
  createThread(th, blockedPollBody, addr blocked)
  check waitFlag(blocked.entered)
  os.sleep(100) # let it reach the wait
  body
  joinThread(th)

suite "a context that ends wakes its poller":
  test "recycle: a poll blocked forever returns RET_CLOSED":
    var pool: FFIContextPool[TestCloseLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    withBlockedPoller(ctx, blocked):
      check pool.recycleFFIContext(ctx).isOk()
    check blocked.ret.load() == int(RET_CLOSED)
    check blocked.kind.load() == MsgClosed

  test "destroy: a poll blocked forever returns RET_CLOSED":
    var pool: FFIContextPool[TestCloseLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    withBlockedPoller(ctx, blocked):
      check pool.destroyFFIContext(ctx).isOk()
    check blocked.ret.load() == int(RET_CLOSED)

suite "the next owner of a slot":
  test "sees none of the messages the last owner left, and the old token is dead":
    var pool: FFIContextPool[TestCloseLib]
    let first = pool.createFFIContext().valueOr:
      check false
      return
    let oldGeneration = first.currentGeneration()
    emit(first, 10)
    check pool.recycleFFIContext(first).isOk()

    let second = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(second)
    # The pool hands the freed slot out again.
    check second == first
    check pollMsg(second, 0).ret == RET_TIMEOUT
    check pollMsg(second, oldGeneration, 0).ret == RET_INVALID_CTX

    emit(second, 1)
    let got = pollMsg(second)
    check got.ret == RET_OK
    check cborDecode(got.payload, LatchPayload).value.iter == 0

  test "events still queued at a destroy are delivered before RET_CLOSED":
    var pool: FFIContextPool[TestCloseLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    let generation = ctx.currentGeneration()
    emit(ctx, 3)
    # Stop the thread but keep the slot: the queue outlives the FFI thread.
    check ctx.stopAndJoinThreads().isOk()
    for _ in 0 ..< 3:
      check pollMsg(ctx, generation, 0).kind == MsgEvent
    check pollMsg(ctx, generation, 0).ret == RET_CLOSED
    # The thread is joined already, so free the slot's resources directly.
    check ctx.deinitContextResources().isOk()

suite "create, poll and destroy race":
  test "many cycles with a poller that never stops":
    var pool: FFIContextPool[TestCloseLib]
    for cycle in 0 ..< 25:
      let ctx = pool.createFFIContext().valueOr:
        check false
        return
      withBlockedPoller(ctx, blocked):
        emit(ctx, 5)
        check pool.recycleFFIContext(ctx).isOk()
      # The poller returned on an event or on the close; both are valid.
      check blocked.ret.load() in [int(RET_OK), int(RET_CLOSED)]
