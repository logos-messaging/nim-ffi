## `<lib>_poll`: the host takes the context's messages out, one at a time, on a
## thread of its own. Nothing here allocates on the Nim heap or touches chronos,
## so any host thread may call it without registering with the Nim runtime.

import std/[atomics, locks, monotimes, times]
import chronos/timer
import ./ffi_context, ./ffi_msg, ./ffi_wake, ./ret_codes

const
  WatchSliceMs = 1000 ## A blocked poll still looks at the heartbeat this often.
  HeartbeatStartDelayMs = FFIHeartbeatStartDelay.milliseconds
  HeartbeatStaleMs = FFIHeartbeatStaleThreshold.milliseconds

const QuarantineReasons = block:
  # Static text: the poller must not build a Nim string.
  var texts: array[RecycleFailure, string]
  for failure in RecycleFailure:
    texts[failure] = reason(failure)
  texts

proc fill(
    msg: ptr ptr PollResult,
    outb: var FFIOutbound,
    kind: uint32,
    seqNum: uint64 = 0,
    id: uint64 = 0,
    nameId: uint64 = 0,
    durationMs: uint64 = 0,
    retCode: cint = RET_OK,
    payload: pointer = nil,
    len: int = 0,
) =
  var data = payload
  if data.isNil() or len <= 0:
    data = cast[pointer](emptyListenerPayload)
  outb.heldMsgSlot = 1 - outb.heldMsgSlot
  outb.heldMsg[outb.heldMsgSlot] = PollResult(
    structSize: uint32(sizeof(PollResult)),
    kind: kind,
    seqNum: seqNum,
    id: id,
    nameId: nameId,
    durationMs: durationMs,
    retCode: int32(retCode),
    flags: 0,
    payload: data,
    len: csize_t(max(len, 0)),
  )
  msg[] = addr outb.heldMsg[outb.heldMsgSlot]

proc fillClosed[T](msg: ptr ptr PollResult, ctx: ptr FFIContext[T]) =
  let seqNum = ctx[].outbound.nextSeq()
  if ctx.lifecycle.load() != CtxLifecycle.RecycleFailed:
    fill(msg, ctx[].outbound, MsgClosed, seqNum = seqNum)
    return
  let text = cstring(QuarantineReasons[ctx.recycleFailure.load()])
  fill(
    msg,
    ctx[].outbound,
    MsgClosed,
    seqNum = seqNum,
    retCode = RET_ERR,
    payload = cast[pointer](text),
    len = text.len,
  )

proc msBetween(earlier, later: MonoTime): int64 =
  return (later - earlier).inMilliseconds

proc checkLiveness[T](
    ctx: ptr FFIContext[T], generation: uint, msg: ptr ptr PollResult
): bool =
  ## True when `msg` was filled with a liveness report. Each report latches once
  ## per episode. The watchdog lives here because the host's own thread is the
  ## one that must hear about a stalled library.
  # A recycle parks the FFI loop in the teardown on purpose; a stall there is not a fault.
  if ctx.lifecycle.load() != CtxLifecycle.Active:
    return false

  let now = getMonoTime()
  let watch = addr ctx[].outbound.watch
  if watch.generation != generation:
    watch[] = HeartbeatWatch(generation: generation, startedAt: now)

  if not watch.notifiedStuck and ctx.eventQueueStuck.load():
    watch.notifiedStuck = true
    fill(msg, ctx[].outbound, MsgNotRespondingQueueFull)
    return true

  if msBetween(watch.startedAt, now) <= HeartbeatStartDelayMs:
    return false

  # The age of the last beat, not whether the value moved since the last poll:
  # a host that polls rarely would otherwise hear of a stall one poll late.
  # A thread that never beat has been silent since the watch began.
  let lastBeat = ctx.ffiHeartbeat.load()
  var silentMs = msBetween(watch.startedAt, now)
  if lastBeat != 0:
    silentMs = (now.ticks - lastBeat) div 1_000_000
  let stale = silentMs > HeartbeatStaleMs
  if not stale:
    if watch.notifiedStale:
      watch.notifiedStale = false
      fill(msg, ctx[].outbound, MsgResponding)
      return true
  elif not watch.notifiedStale:
    watch.notifiedStale = true
    fill(msg, ctx[].outbound, MsgNotRespondingHeartbeat)
    return true
  return false

proc releaseHeld(outb: var FFIOutbound) =
  ## Ends the host's use of the message it last polled.
  if outb.queueLive:
    releaseHeldEvent(outb.held)
  if not outb.heldReplyReq.isNil():
    outb.retireRequest(outb.heldReplyReq)
    outb.heldReplyReq = nil

proc hasMessage[T](ctx: ptr FFIContext[T]): bool =
  let outb = addr ctx[].outbound
  # The count, not `headSeq() != 0`: an event nobody numbered has seqNum 0.
  if outb.queueLive and ctx[].eventQueue.hasEvents():
    return true
  return outb[].replyHeadSeq() != 0 or outb[].staleHeadSeq() != 0

func earliest(firstSeq, secondSeq: uint64): uint64 =
  ## A `seqNum` is the ticket a message takes when it becomes visible to the
  ## host: one counter per context, handed out by `nextSeq`, so a smaller number
  ## means the library produced it earlier. Tickets are never reused and never 0,
  ## which is why 0 can stand for "that queue has nothing".
  ##
  ## Returns the older of the two.
  if firstSeq == 0:
    return secondSeq
  if secondSeq == 0:
    return firstSeq
  if firstSeq < secondSeq:
    return firstSeq
  return secondSeq

proc takeReply(msg: ptr ptr PollResult, outb: var FFIOutbound): bool =
  ## The request stays alive until the next poll: `msg.payload` points into it.
  let reply = outb.popReply()
  if reply.isNil():
    return false
  outb.heldReplyReq = reply
  fill(
    msg,
    outb,
    MsgReply,
    seqNum = reply[].seqNum,
    id = reply[].id,
    retCode = reply[].retCode,
    payload = reply[].data,
    len = reply[].dataLen,
  )
  return true

proc takeStaleReq(msg: ptr ptr PollResult, outb: var FFIOutbound): bool =
  ## Only the figures travel; the request itself is still with the FFI thread.
  var reqId, seqNum: uint64
  var elapsedMs: int64
  if not outb.popStaleReq(reqId, seqNum, elapsedMs):
    return false
  fill(msg, outb, MsgStale, seqNum = seqNum, id = reqId, durationMs = uint64(elapsedMs))
  return true

proc takeEvent[T](msg: ptr ptr PollResult, ctx: ptr FFIContext[T]): bool =
  ## Moves the oldest event into `held`, which frees its ring slot at once.
  let outb = addr ctx[].outbound
  if not outb.queueLive or not ctx[].eventQueue.popEventInto(outb.held):
    return false
  let ev = outb.held.event
  fill(
    msg,
    outb[],
    MsgEvent,
    seqNum = ev.seqNum,
    nameId = ev.nameId,
    payload = ev.data,
    len = ev.dataLen,
  )
  return true

proc takeMessage[T](ctx: ptr FFIContext[T], msg: ptr ptr PollResult): bool =
  ## Hands out the oldest of what the context has ready — a queued reply, a
  ## pending stale request, or an event — so the host sees the order the library
  ## produced and no source starves another.
  ##
  ## Each source is asked for its ticket, then the winner is asked to take its
  ## message. Looking and taking need not be one atomic step: this thread is the
  ## only consumer, so the FFI thread can add messages in between but never
  ## remove the one that was chosen.
  let outb = addr ctx[].outbound

  var eventSeq = 0'u64
  if outb.queueLive:
    eventSeq = ctx[].eventQueue.headSeq()
  let replySeq = outb[].replyHeadSeq()
  let staleSeq = outb[].staleHeadSeq()

  let oldest = earliest(earliest(eventSeq, replySeq), staleSeq)
  if oldest == 0:
    # An event nobody numbered still has to come out, and it is the only
    # message a context can hold without a ticket.
    return takeEvent(msg, ctx)
  if oldest == replySeq:
    return takeReply(msg, outb[])
  if oldest == staleSeq:
    return takeStaleReq(msg, outb[])
  return takeEvent(msg, ctx)

proc pollContext*[T](
    ctx: ptr FFIContext[T], generation: uint, timeoutMs: int, msg: ptr ptr PollResult
): cint {.raises: [], gcsafe.} =
  ## `generation` is the claim the caller's token was issued under. 0 never
  ## blocks, a negative timeout waits until a message or the end of the context.
  ## `msg[]` points at the message on `RET_OK` and `RET_CLOSED`, and is nil otherwise.
  if msg.isNil():
    return RET_ERR
  msg[] = nil
  if ctx.isNil():
    return RET_ERR

  let outb = addr ctx[].outbound
  # One consumer. A second one is turned away, not parked behind a poll that may
  # wait forever. Teardown takes the same lock, but only to drop the queues and
  # never waits on anything, so a poller whose context is ending waits it out
  # rather than reporting another poller that is not there.
  if not outb.pollLock.tryAcquire():
    # A past owner's token must not wait behind the live owner's poller.
    if ctx.generation.load() != generation:
      return RET_INVALID_CTX
    if outb.closedGeneration.load() != generation:
      return RET_BUSY
    outb.pollLock.acquire()
  defer:
    outb.pollLock.release()

  # Before anything owned by the slot is touched: a token from a past owner must
  # not release what the owner that holds the slot now was handed.
  if ctx.generation.load() != generation:
    return RET_INVALID_CTX

  outb.polledGeneration.store(generation)
  releaseHeld(outb[])

  let start = getMonoTime()
  while true:
    if ctx.generation.load() != generation:
      # The slot changed owner while this poll waited: the queues are not ours.
      fill(msg, outb[], MsgClosed)
      return RET_CLOSED

    if checkLiveness(ctx, generation, msg):
      return RET_OK

    if takeMessage(ctx, msg):
      return RET_OK

    # After the queues, so the messages of a teardown still arrive.
    if outb.closedGeneration.load() == generation:
      fillClosed(msg, ctx)
      return RET_CLOSED

    # Disarm, then look again: a producer that saw the wake armed did not fire.
    outb.wakeArmed.store(false)
    outb.wake.clear()
    if hasMessage(ctx) or outb.closedGeneration.load() == generation or
        ctx.generation.load() != generation:
      continue

    var slice = WatchSliceMs
    if timeoutMs >= 0:
      let remaining = int64(timeoutMs) - msBetween(start, getMonoTime())
      if remaining <= 0:
        return RET_TIMEOUT
      slice = int(min(remaining, int64(WatchSliceMs)))
    discard outb.wake.waitFor(slice)

proc pollContextHandle*[T](ctx: ptr FFIContext[T]): int {.raises: [], gcsafe.} =
  ## A wake handle the host owns: ready while a message waits or the context is
  ## closed. The host waits on it, then polls with a timeout of 0 until `RET_TIMEOUT`.
  ## Every call makes a new handle, and the host closes each one it was given:
  ## ask once per context and keep it.
  if ctx.isNil():
    return WakeNoHandle
  return ctx[].outbound.wake.hostHandle()
