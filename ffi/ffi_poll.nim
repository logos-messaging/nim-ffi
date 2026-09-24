## `<lib>_poll`: the host takes the context's messages out, one at a time, on a
## thread of its own. Nothing here allocates on the Nim heap or touches chronos,
## so any host thread may call it without registering with the Nim runtime.

import std/[atomics, locks, monotimes, times]
import chronos/timer
import ./ffi_context, ./ffi_msg, ./ffi_wake, ./ffi_thread_request, ./ret_codes

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
    msg: ptr ptr NimFfiMsg,
    outb: var FFIOutbound,
    kind: uint32,
    seq: uint64 = 0,
    id: uint64 = 0,
    nameId: uint64 = 0,
    aux: uint64 = 0,
    retCode: cint = RET_OK,
    payload: pointer = nil,
    len: int = 0,
) =
  var data = payload
  if data.isNil() or len <= 0:
    data = cast[pointer](emptyListenerPayload)
  var msgSeq = seq
  if msgSeq == 0:
    msgSeq = outb.nextSeq()
  outb.heldMsgSlot = 1 - outb.heldMsgSlot
  outb.heldMsg[outb.heldMsgSlot] = NimFfiMsg(
    structSize: uint32(sizeof(NimFfiMsg)),
    kind: kind,
    seq: msgSeq,
    id: id,
    nameId: nameId,
    aux: aux,
    retCode: int32(retCode),
    flags: 0,
    payload: data,
    len: csize_t(max(len, 0)),
  )
  msg[] = addr outb.heldMsg[outb.heldMsgSlot]

proc fillClosed[T](msg: ptr ptr NimFfiMsg, ctx: ptr FFIContext[T]) =
  if ctx.lifecycle.load() != CtxLifecycle.RecycleFailed:
    fill(msg, ctx[].outbound, MsgClosed)
    return
  let text = cstring(QuarantineReasons[ctx.recycleFailure.load()])
  fill(
    msg,
    ctx[].outbound,
    MsgClosed,
    retCode = RET_ERR,
    payload = cast[pointer](text),
    len = text.len,
  )

proc msBetween(earlier, later: MonoTime): int64 =
  return (later - earlier).inMilliseconds

proc checkLiveness[T](
    ctx: ptr FFIContext[T], generation: uint, msg: ptr ptr NimFfiMsg
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
    watch[] = HeartbeatWatch(
      generation: generation,
      startedAt: now,
      lastChange: now,
      lastValue: ctx.ffiHeartbeat.load(),
    )

  if not watch.notifiedStuck and ctx.eventQueueStuck.load():
    watch.notifiedStuck = true
    fill(msg, ctx[].outbound, MsgNotResponding, aux = NotRespondingEventQueueFull)
    return true

  if msBetween(watch.startedAt, now) <= HeartbeatStartDelayMs:
    return false

  let cur = ctx.ffiHeartbeat.load()
  if cur != watch.lastValue:
    watch.lastValue = cur
    watch.lastChange = now
    if watch.notifiedStale:
      watch.notifiedStale = false
      fill(msg, ctx[].outbound, MsgResponding)
      return true
  elif not watch.notifiedStale and msBetween(watch.lastChange, now) > HeartbeatStaleMs:
    watch.notifiedStale = true
    fill(msg, ctx[].outbound, MsgNotResponding, aux = NotRespondingHeartbeat)
    return true
  return false

proc releaseHeld(outb: var FFIOutbound) =
  ## Ends the host's use of the message it last polled.
  if outb.queueLive:
    releaseHeldEvent(outb.held)
  if not outb.heldReply.isNil():
    outb.retireRequest(outb.heldReply)
    outb.heldReply = nil

proc hasMessage[T](ctx: ptr FFIContext[T]): bool =
  let outb = addr ctx[].outbound
  if outb.queueLive and ctx[].eventQueue.headSeq() != 0:
    return true
  withLock outb.lock:
    return not outb.replyHead.isNil() or not outb.staleHead.isNil()

proc takeMessage[T](ctx: ptr FFIContext[T], msg: ptr ptr NimFfiMsg): bool =
  ## Hands out the oldest message of the three queues, so the host sees the
  ## order the library produced and no kind can starve another.
  let outb = addr ctx[].outbound
  var eventSeq = 0'u64
  if outb.queueLive:
    eventSeq = ctx[].eventQueue.headSeq()

  var
    reply: ptr FFIThreadRequest = nil
    staleId, staleSeq: uint64
    staleMs: int64
    gotStale = false
  withLock outb.lock:
    var replySeq = 0'u64
    if not outb.replyHead.isNil():
      replySeq = outb.replyHead[].seq
    var staleHeadSeq = 0'u64
    if not outb.staleHead.isNil():
      staleHeadSeq = outb.staleHead[].staleSeq

    # The event queue has one consumer, this thread, so its head cannot move under us.
    var oldest = eventSeq
    if replySeq != 0 and (oldest == 0 or replySeq < oldest):
      oldest = replySeq
    if staleHeadSeq != 0 and (oldest == 0 or staleHeadSeq < oldest):
      oldest = staleHeadSeq
    if oldest == 0:
      return false
    if oldest == replySeq:
      reply = outb[].popReply()
    elif oldest == staleHeadSeq:
      gotStale = outb[].popStaleWarn(staleId, staleSeq, staleMs)

  if not reply.isNil():
    outb.heldReply = reply
    fill(
      msg,
      outb[],
      MsgReply,
      seq = reply[].seq,
      id = reply[].id,
      retCode = reply[].retCode,
      payload = reply[].data,
      len = reply[].dataLen,
    )
    return true
  if gotStale:
    fill(msg, outb[], MsgStaleWarn, seq = staleSeq, id = staleId, aux = uint64(staleMs))
    return true
  if outb.queueLive and ctx[].eventQueue.popEventInto(outb.held):
    let ev = outb.held.event
    fill(
      msg,
      outb[],
      MsgEvent,
      seq = ev.seq,
      nameId = ev.nameId,
      payload = ev.data,
      len = ev.dataLen,
    )
    return true
  return false

proc pollContext*[T](
    ctx: ptr FFIContext[T], generation: uint, timeoutMs: int, msg: ptr ptr NimFfiMsg
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
    if outb.closedGeneration.load() != generation and ctx.generation.load() == generation:
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
  if ctx.isNil():
    return WakeNoHandle
  return ctx[].outbound.wake.hostHandle()
