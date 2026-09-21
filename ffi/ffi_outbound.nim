## What a context keeps for its poller: the wake, the lock that makes polling
## single-consumer, the message counter, the reply and stale-warning queues and
## the message last handed out. Nothing here runs chronos: the poller is a host thread.

import std/[atomics, locks, monotimes]
import results
import ./ffi_wake, ./ffi_events, ./ffi_msg, ./ffi_thread_request

type
  HeartbeatWatch* = object
    ## Poller-side view of the FFI thread's heartbeat. Guarded by `pollLock`.
    generation*: uint
    startedAt*: MonoTime
    lastChange*: MonoTime
    lastValue*: int64
    notifiedStale*: bool
    notifiedStuck*: bool

  FFIOutbound* = object
    ## Lives as long as its pool slot, like the slot's signals: a host thread may
    ## sit in `poll` whatever the context is doing.
    ready: bool
    pollLock*: Lock
    wake*: WakeSignal
    wakeArmed*: Atomic[bool]
    msgSeq*: Atomic[uint64]
    closedGeneration*: Atomic[uint]
      # The claim whose messages ended. A claim is never 0, so 0 closes nothing.
    polledGeneration*: Atomic[uint] # The last claim a host polled under.
    queueLive*: bool
      # Guarded by `pollLock`: false while the event queue and `held` are torn down.
    lock*: Lock # Guards the reply and the stale-warning list.
    replyHead*, replyTail*: ptr FFIThreadRequest
      # Answered requests, linked through `next`. Never dropped: a lost reply
      # leaves its caller waiting, so events have a bounded queue of their own.
    staleHead*, staleTail*: ptr FFIThreadRequest
      # Requests with a warning pending, linked through `staleNext`.
    outstanding*: Atomic[int] # Submitted requests the host has not collected yet.
    held*: HeldEvent
    heldReply*: ptr FFIThreadRequest # The reply the host reads; freed at the next poll.
    heldMsg*: NimFfiMsg
      # What `poll` hands out. The library owns it, so appending a field to
      # `NimFfiMsg` never writes past a struct an older host allocated.
    watch*: HeartbeatWatch

proc initOutbound*(outb: var FFIOutbound): Result[void, string] =
  ## Idempotent: a rebuilt slot keeps its outbound (re-initLock is UB).
  if outb.ready:
    return ok()
  ?outb.wake.init()
  outb.pollLock.initLock()
  outb.lock.initLock()
  outb.ready = true
  return ok()

proc nextSeq*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  return outb.msgSeq.fetchAdd(1) + 1

proc notifyOutbound*(outb: var FFIOutbound) {.raises: [], gcsafe.} =
  ## Producer side, after an enqueue. One syscall per burst: the poller disarms
  ## only once it found the queues empty.
  if not outb.wakeArmed.exchange(true):
    outb.wake.fire()

proc closeOutbound*(outb: var FFIOutbound, generation: uint) {.raises: [], gcsafe.} =
  ## Ends the messages of `generation` and wakes its poller, which then gets `RET_CLOSED`.
  outb.closedGeneration.store(generation)
  outb.wake.fire()

proc retireRequest*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest
) {.raises: [], gcsafe.} =
  ## Frees a request that was submitted: answered and collected, or dropped.
  if request.isNil():
    return
  deleteRequest(request)
  outb.outstanding.atomicDec()

proc unlinkStale(outb: var FFIOutbound, request: ptr FFIThreadRequest) =
  ## Call with `outb.lock` held.
  if not request[].staleQueued:
    return
  var prev: ptr FFIThreadRequest = nil
  var cur = outb.staleHead
  while not cur.isNil() and cur != request:
    prev = cur
    cur = cur[].staleNext
  if not cur.isNil():
    if prev.isNil():
      outb.staleHead = cur[].staleNext
    else:
      prev[].staleNext = cur[].staleNext
    if outb.staleTail == cur:
      outb.staleTail = prev
  request[].staleNext = nil
  request[].staleQueued = false

proc enqueueReply*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest
) {.raises: [], gcsafe.} =
  ## FFI thread. `request` already carries its reply (`setReply`).
  request[].next = nil
  withLock outb.lock:
    # The reply says more than a warning about the same request.
    outb.unlinkStale(request)
    request[].seq = outb.nextSeq()
    if outb.replyTail.isNil():
      outb.replyHead = request
    else:
      outb.replyTail[].next = request
    outb.replyTail = request
  outb.notifyOutbound()

proc enqueueStaleWarn*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest, elapsedMs: int64
) {.raises: [], gcsafe.} =
  ## FFI thread. At most one warning waits per request, so a host that polls
  ## slowly finds the latest figure, not a backlog.
  withLock outb.lock:
    request[].staleElapsedMs = elapsedMs
    if request[].staleQueued:
      return
    request[].staleQueued = true
    request[].staleSeq = outb.nextSeq()
    request[].staleNext = nil
    if outb.staleTail.isNil():
      outb.staleHead = request
    else:
      outb.staleTail[].staleNext = request
    outb.staleTail = request
  outb.notifyOutbound()

proc popReply*(outb: var FFIOutbound): ptr FFIThreadRequest {.raises: [], gcsafe.} =
  ## Call with `outb.lock` held.
  let request = outb.replyHead
  if request.isNil():
    return nil
  outb.replyHead = request[].next
  if outb.replyHead.isNil():
    outb.replyTail = nil
  request[].next = nil
  return request

proc popStaleWarn*(
    outb: var FFIOutbound, reqId: var uint64, seq: var uint64, elapsedMs: var int64
): bool {.raises: [], gcsafe.} =
  ## Call with `outb.lock` held. Copies the warning out: the request stays with the FFI thread.
  let request = outb.staleHead
  if request.isNil():
    return false
  reqId = request[].reqId
  seq = request[].staleSeq
  elapsedMs = request[].staleElapsedMs
  outb.unlinkStale(request)
  return true

proc dropQueuedMessages*(
    outb: var FFIOutbound, q: var EventQueue
) {.raises: [], gcsafe.} =
  ## The next owner of the slot must not see these. Waits for a poller to leave
  ## `poll`, so call `closeOutbound` first. What the host still holds is untouched.
  withLock outb.pollLock:
    clearEventQueue(q)
    var replies: ptr FFIThreadRequest = nil
    withLock outb.lock:
      replies = outb.replyHead
      outb.replyHead = nil
      outb.replyTail = nil
      # Every request with a warning pending was drained or rejected by now.
      outb.staleHead = nil
      outb.staleTail = nil
    while not replies.isNil():
      let nextReply = replies[].next
      outb.retireRequest(replies)
      replies = nextReply
