## Events reach the host through `poll`: payload shape, order, lifetime, the
## single-consumer rule, the wake handle and the event-queue overflow.

import std/[atomics, os, strutils]
import unittest2
import results
import ffi
import ffi/ffi_wake
import ./helpers, ./host_wait

type TestPollLib = object

type MessageSentBody* {.ffi.} = object
  requestId*: string
  messageHash*: string

type LatchPayload* {.ffi.} = object
  iter*: int

template withPool(ctxIdent: untyped, body: untyped) =
  var pool: FFIContextPool[TestPollLib]
  let ctxIdent = pool.createFFIContext().valueOr:
    check false
    return
  defer:
    discard pool.destroyFFIContext(ctxIdent)
  body

registerReqFFI(EmitCborEventRequest, lib: ptr TestPollLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEventCbor(
      "message_sent", MessageSentBody(requestId: "req-1", messageHash: "0xdeadbeef")
    )
    return ok("emitted")

registerReqFFI(EmitRawBytesEventRequest, lib: ptr TestPollLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEvent("raw_bytes"):
      @[byte 0x01, 0x02, 0x03]
    return ok("emitted")

registerReqFFI(EmitOversizeRequest, lib: ptr TestPollLib):
  proc(size: int): Future[Result[string, string]] {.async.} =
    var body = newSeq[byte](size)
    for i in 0 ..< size:
      body[i] = byte(i and 0xFF)
    dispatchFFIEvent("oversize"):
      body
    return ok("emitted")

registerReqFFI(BurstEmit, lib: ptr TestPollLib):
  proc(count: int): Future[Result[string, string]] {.async.} =
    for i in 0 ..< count:
      dispatchFFIEventCbor("latch", LatchPayload(iter: i))
    return ok("bursted")

registerReqFFI(EmitLater, lib: ptr TestPollLib):
  proc(delayMs: int): Future[Result[string, string]] {.async.} =
    await sleepAsync(delayMs.milliseconds)
    dispatchFFIEventCbor("latch", LatchPayload(iter: 7))
    return ok("emitted")

registerReqFFI(Ping, lib: ptr TestPollLib):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("pong")

template request(ctx: untyped, req: untyped) {.dirty.} =
  ## Replies still arrive through the callback; wait for it so the events are queued.
  block:
    setupCallbackData(rsp)
    check sendRequestToFFIThread(ctx, req).isOk()
    waitCallback(rsp)
    check rsp.retCode == RET_OK

suite "events through poll":
  test "a typed event carries its name id and the bare CBOR payload":
    withPool(ctx):
      request(ctx, EmitCborEventRequest.ffiNewReq(testCallback, addr rsp))

      let got = pollMsg(ctx)
      check got.ret == RET_OK
      check got.kind == MsgEvent
      check got.nameId == nameId("message_sent")
      let decoded = cborDecode(got.payload, MessageSentBody)
      check decoded.isOk()
      check decoded.value.requestId == "req-1"
      check decoded.value.messageHash == "0xdeadbeef"

  test "a raw event body arrives as is":
    withPool(ctx):
      request(ctx, EmitRawBytesEventRequest.ffiNewReq(testCallback, addr rsp))

      let got = pollMsg(ctx)
      check got.ret == RET_OK
      check got.nameId == nameId("raw_bytes")
      check got.payload == @[byte 0x01, 0x02, 0x03]

  test "a payload above the slab budget arrives intact":
    withPool(ctx):
      let size = MaxEventPayloadBytes + 64
      request(ctx, EmitOversizeRequest.ffiNewReq(testCallback, addr rsp, size))

      let got = pollMsg(ctx)
      check got.ret == RET_OK
      check got.payload.len == size
      var intact = true
      for i in 0 ..< got.payload.len:
        if got.payload[i] != byte(i and 0xFF):
          intact = false
      check intact

  test "events arrive in the order they were produced":
    withPool(ctx):
      const Count = 50
      request(ctx, BurstEmit.ffiNewReq(testCallback, addr rsp, Count))

      var lastSeq = 0'u64
      for i in 0 ..< Count:
        let got = pollMsg(ctx)
        check got.ret == RET_OK
        check got.seq > lastSeq
        lastSeq = got.seq
        check cborDecode(got.payload, LatchPayload).value.iter == i
      check pollMsg(ctx, 0).ret == RET_TIMEOUT

suite "poll timeouts":
  test "a timeout of 0 never blocks":
    withPool(ctx):
      let start = Moment.now()
      check pollMsg(ctx, 0).ret == RET_TIMEOUT
      check Moment.now() - start < 100.milliseconds

  test "a positive timeout waits that long":
    withPool(ctx):
      let start = Moment.now()
      check pollMsg(ctx, 150).ret == RET_TIMEOUT
      let took = Moment.now() - start
      check took >= 100.milliseconds
      check took < 2.seconds

  test "an event produced later wakes a blocked poll":
    withPool(ctx):
      setupCallbackData(rsp)
      check sendRequestToFFIThread(
        ctx, EmitLater.ffiNewReq(testCallback, addr rsp, 100)
      )
        .isOk()
      let start = Moment.now()
      let got = pollMsg(ctx, 5000)
      check got.ret == RET_OK
      check got.kind == MsgEvent
      check Moment.now() - start < 4.seconds
      waitCallback(rsp)

suite "message lifetime":
  test "a message stays valid until the next poll, whatever the producer does":
    withPool(ctx):
      request(ctx, EmitRawBytesEventRequest.ffiNewReq(testCallback, addr rsp))

      var msg: ptr NimFfiMsg
      check pollContext(ctx, ctx.currentGeneration(), 1000, addr msg) == RET_OK
      # The producer now reuses the ring slot the held event came from.
      request(
        ctx, BurstEmit.ffiNewReq(testCallback, addr rsp, EventQueueCapacity div 2)
      )
      check msg.len == 3
      let held = cast[ptr UncheckedArray[byte]](msg.payload)
      check held[0] == 0x01
      check held[1] == 0x02
      check held[2] == 0x03

type BlockedPoll = object
  ctx: ptr FFIContext[TestPollLib]
  generation: uint
  entered: Atomic[bool]
  ret: Atomic[int]

proc blockedPollBody(args: ptr BlockedPoll) {.thread.} =
  var msg: ptr NimFfiMsg
  args.entered.store(true)
  args.ret.store(int(pollContext(args.ctx, args.generation, 5000, addr msg)))

suite "one consumer at a time":
  test "a second poller gets RET_BUSY while the first one waits":
    withPool(ctx):
      var blocked = BlockedPoll(ctx: ctx, generation: ctx.currentGeneration())
      blocked.ret.store(-1)
      var th: Thread[ptr BlockedPoll]
      createThread(th, blockedPollBody, addr blocked)
      check waitFlag(blocked.entered)
      os.sleep(100) # let it reach the wait

      check pollMsg(ctx, 0).ret == RET_BUSY

      request(ctx, EmitRawBytesEventRequest.ffiNewReq(testCallback, addr rsp))
      joinThread(th)
      check blocked.ret.load() == int(RET_OK)

suite "tokens":
  test "a generation that is not the live claim is refused":
    withPool(ctx):
      check pollMsg(ctx, ctx.currentGeneration() + 2, 0).ret == RET_INVALID_CTX

  test "a nil message is an error":
    withPool(ctx):
      check pollContext(ctx, ctx.currentGeneration(), 0, nil) == RET_ERR

suite "wake handle":
  test "the handle is ready while a message waits, and the host owns its copy":
    withPool(ctx):
      let handle = pollContextHandle(ctx)
      check handle != WakeNoHandle
      check pollMsg(ctx, 0).ret == RET_TIMEOUT
      check not hostSeesReady(handle, 0)

      request(ctx, BurstEmit.ffiNewReq(testCallback, addr rsp, 3))
      check hostSeesReady(handle, 2000)

      # Still ready with messages left; not ready once poll answered RET_TIMEOUT.
      check pollMsg(ctx, 0).ret == RET_OK
      check pollMsg(ctx, 0).ret == RET_OK
      check pollMsg(ctx, 0).ret == RET_OK
      check pollMsg(ctx, 0).ret == RET_TIMEOUT
      check not hostSeesReady(handle, 0)

      # Closing the host's copy leaves the library's wake working.
      closeHostHandle(handle)
      request(ctx, EmitRawBytesEventRequest.ffiNewReq(testCallback, addr rsp))
      check pollMsg(ctx, 2000).ret == RET_OK

suite "event queue overflow":
  test "a host that never polled loses the events, not its requests":
    withPool(ctx):
      request(ctx, BurstEmit.ffiNewReq(testCallback, addr rsp, EventQueueCapacity + 8))
      check not ctx.eventQueueStuck.load()
      request(ctx, Ping.ffiNewReq(testCallback, addr rsp))
      check pollMsg(ctx).kind == MsgEvent

  test "overflow marks the context stuck, poll reports it once, requests are refused":
    withPool(ctx):
      # A host that polls wants its events: losing one is a fault, not a preference.
      check pollMsg(ctx, 0).ret == RET_TIMEOUT
      request(ctx, BurstEmit.ffiNewReq(testCallback, addr rsp, EventQueueCapacity + 8))
      check ctx.eventQueueStuck.load()

      setupCallbackData(rejected)
      let res = sendRequestToFFIThread(ctx, Ping.ffiNewReq(testCallback, addr rejected))
      check res.isErr()
      check res.error.contains("stuck")

      let report = pollMsg(ctx)
      check report.ret == RET_OK
      check report.kind == MsgNotResponding
      check report.aux == NotRespondingEventQueueFull

      # The report is not repeated, and the events that did fit are all there.
      var events = 0
      while true:
        let got = pollMsg(ctx, 0)
        if got.ret != RET_OK:
          break
        check got.kind == MsgEvent
        events.inc()
      check events == EventQueueCapacity
