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

template request(ctx: untyped, req: untyped) =
  ## Waits for the reply. The events the handler produced came first, so
  ## `nextMsg` hands them out afterwards.
  check call(ctx, req).retCode == RET_OK

template submit(ctx: untyped, req: untyped) =
  ## Sends without polling: for a test about what waits in the queues.
  check sendRequestToFFIThread(ctx, req).isOk()

template waitUntil(cond: untyped) =
  block:
    let deadline = Moment.now() + 5.seconds
    while not (cond) and Moment.now() < deadline:
      os.sleep(2)
    check cond

suite "events through poll":
  test "a typed event carries its name id and the bare CBOR payload":
    withPool(ctx):
      request(ctx, EmitCborEventRequest.ffiNewReq())

      let got = nextMsg(ctx)
      check got.ret == RET_OK
      check got.kind == MsgEvent
      check got.nameId == nameId("message_sent")
      let decoded = cborDecode(got.payload, MessageSentBody)
      check decoded.isOk()
      check decoded.value.requestId == "req-1"
      check decoded.value.messageHash == "0xdeadbeef"

  test "a raw event body arrives as is":
    withPool(ctx):
      request(ctx, EmitRawBytesEventRequest.ffiNewReq())

      let got = nextMsg(ctx)
      check got.ret == RET_OK
      check got.nameId == nameId("raw_bytes")
      check got.payload == @[byte 0x01, 0x02, 0x03]

  test "a payload above the slab budget arrives intact":
    withPool(ctx):
      let size = MaxEventPayloadBytes + 64
      request(ctx, EmitOversizeRequest.ffiNewReq(size))

      let got = nextMsg(ctx)
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
      request(ctx, BurstEmit.ffiNewReq(Count))

      var lastSeq = 0'u64
      for i in 0 ..< Count:
        let got = nextMsg(ctx)
        check got.ret == RET_OK
        check got.seq > lastSeq
        lastSeq = got.seq
        check cborDecode(got.payload, LatchPayload).value.iter == i
      check nextMsg(ctx, 0).ret == RET_TIMEOUT

suite "poll timeouts":
  test "a timeout of 0 never blocks":
    withPool(ctx):
      let start = Moment.now()
      check nextMsg(ctx, 0).ret == RET_TIMEOUT
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
      submit(ctx, EmitLater.ffiNewReq(100))
      let start = Moment.now()
      let got = pollMsg(ctx, 5000)
      check got.ret == RET_OK
      check got.kind == MsgEvent
      check Moment.now() - start < 4.seconds
      check pollMsg(ctx, 5000).kind == MsgReply

suite "message lifetime":
  test "a message stays valid until the next poll, whatever the producer does":
    withPool(ctx):
      submit(ctx, EmitRawBytesEventRequest.ffiNewReq())

      var msg: ptr NimFfiMsg
      check pollContext(ctx, ctx.currentGeneration(), 1000, addr msg) == RET_OK
      check msg.kind == MsgEvent
      # The producer now reuses the ring slot the held event came from.
      submit(ctx, BurstEmit.ffiNewReq(EventQueueCapacity div 2))
      waitUntil(ctx[].eventQueue.count == EventQueueCapacity div 2)
      check msg.len == 3
      let held = cast[ptr UncheckedArray[byte]](msg.payload)
      check held[0] == 0x01
      check held[1] == 0x02
      check held[2] == 0x03

  test "a reply stays valid until the next poll":
    withPool(ctx):
      submit(ctx, Ping.ffiNewReq())
      var msg: ptr NimFfiMsg
      check pollContext(ctx, ctx.currentGeneration(), 1000, addr msg) == RET_OK
      check msg.kind == MsgReply
      check msg.retCode == RET_OK
      # More replies queue up behind it; the held one is a node of its own.
      for _ in 0 ..< 20:
        submit(ctx, Ping.ffiNewReq())
      os.sleep(50)
      var bytes = newSeq[byte](int(msg.len))
      copyMem(addr bytes[0], msg.payload, int(msg.len))
      check cborDecode(bytes, string).value == "pong"

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

      check nextMsg(ctx, 0).ret == RET_BUSY

      submit(ctx, EmitRawBytesEventRequest.ffiNewReq())
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
      check nextMsg(ctx, 0).ret == RET_TIMEOUT
      check not hostSeesReady(handle, 0)

      submit(ctx, BurstEmit.ffiNewReq(3))
      check hostSeesReady(handle, 2000)

      # The host loop: wait on the handle, then drain until RET_TIMEOUT. The reply
      # can land after a drain, which makes the handle ready again.
      var events = 0
      var replies = 0
      while events + replies < 4:
        check hostSeesReady(handle, 2000)
        while true:
          let got = pollMsg(ctx, 0)
          if got.ret != RET_OK:
            check got.ret == RET_TIMEOUT
            break
          if got.kind == MsgEvent:
            events.inc()
          elif got.kind == MsgReply:
            replies.inc()
      check events == 3
      check replies == 1
      check not hostSeesReady(handle, 0)

      # Closing the host's copy leaves the library's wake working.
      closeHostHandle(handle)
      submit(ctx, EmitRawBytesEventRequest.ffiNewReq())
      check pollMsg(ctx, 2000).ret == RET_OK

suite "event queue overflow":
  test "a host that never polled loses the events, not its requests":
    withPool(ctx):
      submit(ctx, BurstEmit.ffiNewReq(EventQueueCapacity + 8))
      waitUntil(ctx[].eventQueue.count == EventQueueCapacity)
      os.sleep(50)
      check not ctx.eventQueueStuck.load()
      check call(ctx, Ping.ffiNewReq()).retCode == RET_OK

  test "overflow marks the context stuck, poll reports it once, requests are refused":
    withPool(ctx):
      # A host that polls wants its events: losing one is a fault, not a preference.
      check pollMsg(ctx, 0).ret == RET_TIMEOUT
      submit(ctx, BurstEmit.ffiNewReq(EventQueueCapacity + 8))
      waitUntil(ctx.eventQueueStuck.load())

      let res = sendRequestToFFIThread(ctx, Ping.ffiNewReq())
      check res.isErr()
      check res.error.contains("stuck")

      let report = pollMsg(ctx)
      check report.ret == RET_OK
      check report.kind == MsgNotResponding
      check report.aux == NotRespondingEventQueueFull

      # The report is not repeated; the events that fit and the reply are all there.
      var events = 0
      var replies = 0
      while true:
        let got = pollMsg(ctx, 200)
        if got.ret != RET_OK:
          break
        if got.kind == MsgEvent:
          events.inc()
        elif got.kind == MsgReply:
          replies.inc()
        else:
          check false
      # The handler was still emitting while this loop freed slots, so a few more fit.
      check events >= EventQueueCapacity
      check events < EventQueueCapacity + 8
      check replies == 1
