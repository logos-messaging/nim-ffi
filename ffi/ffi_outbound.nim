## What a context keeps for a host that pulls its messages instead of being
## called back: the wake, the lock that makes polling single-consumer, the
## message counter and the message last handed out. Nothing here runs chronos:
## the poller is a host thread.

import std/[atomics, locks, monotimes]
import results
import ./ffi_wake, ./ffi_events, ./ffi_msg, ./ffi_request_queue, ./ffi_thread_request

const MaxOutstandingRequests* {.intdefine: "ffiMaxOutstandingRequests".} =
  RequestQueueCount * RequestQueueDepth
  ## Requests submitted but not yet collected by the host. Past it a submit is
  ## refused, so a host that stops polling cannot grow the library without bound.
  ## Defaults to what the ingress queues hold at once.
  ## Override `-d:ffiMaxOutstandingRequests=N`.

type
  HeartbeatWatch* = object
    ## Poller-side view of the FFI thread's heartbeat. Guarded by `pollLock`.
    generation*: uint
    startedAt*: MonoTime
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
    lock*: Lock # Guards the reply and the stale-request lists.
    replyReqHead*, replyReqTail*: ptr FFIThreadRequest
      # Answered requests waiting for the host, linked through `next`.
    staleReqHead*, staleReqTail*: ptr FFIThreadRequest
      # Requests running long enough to report, linked through `staleNext`.
    numNotCollectedReq*: Atomic[int] # Submitted requests the host has not collected yet.
    reqIdSeq*: Atomic[uint64] # Request ids of this slot, over all of its owners.
    held*: HeldEvent
    heldReplyReq*: ptr FFIThreadRequest
      # The reply the host reads; freed at the next poll.
    heldMsg*: array[2, PollResult]
      # What `poll` hands out. The library owns it, so appending a field to
      # `PollResult` never writes past a struct an older host allocated. Two of
      # them, used in turn: a slot outlives its owners, and the next owner's first
      # message must not land in the one the last owner is still reading.
    heldMsgSlot*: int
    watch*: HeartbeatWatch

proc initOutbound*(outb: var FFIOutbound): Result[void, string] =
  ## Idempotent: a rebuilt slot keeps its outbound (re-initLock is UB).
  if outb.ready:
    return ok()
  ?outb.wake.init()
  outb.pollLock.initLock()
  outb.lock.initLock()
  initHeldEvent(outb.held)
  outb.queueLive = true
  outb.ready = true
  return ok()

proc nextSeq*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  ## Numbers a message the moment it becomes pollable: a reply when queued, a
  ## stale warning when first raised, an event when enqueued. One counter per
  ## context, so a lower number was produced earlier; `poll` returns the lowest
  ## across the three queues. Starts at 1 so a queue can report 0 for "empty".
  return outb.msgSeq.fetchAdd(1) + 1

proc nextRequestId*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  return outb.reqIdSeq.fetchAdd(1) + 1

proc notifyOutbound*(outb: var FFIOutbound) {.raises: [], gcsafe.} =
  ## Producer side, after an enqueue. One syscall per burst: the poller disarms, then re-checks the queues, then waits
  if not outb.wakeArmed.exchange(true):
    outb.wake.fire()

proc closeOutbound*(outb: var FFIOutbound, generation: uint) {.raises: [], gcsafe.} =
  ## Ends the messages of `generation` and wakes its poller, which then gets `RET_CLOSED`.
  outb.closedGeneration.store(generation)
  outb.wake.fire()

proc claimOutstanding*(outb: var FFIOutbound): bool {.raises: [], gcsafe.} =
  ## Counts a submit in, or refuses it because the host is not collecting.
  if outb.numNotCollectedReq.fetchAdd(1) >= MaxOutstandingRequests:
    outb.numNotCollectedReq.atomicDec()
    return false
  return true

proc retireRequest*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest
) {.raises: [], gcsafe.} =
  ## Frees a request that was counted in: answered and collected, or dropped.
  if request.isNil():
    return
  deleteRequest(request)
  outb.numNotCollectedReq.atomicDec()

proc unlinkStaleReq(outb: var FFIOutbound, request: ptr FFIThreadRequest) =
  ## Takes `request` off the stale-request queue: either the host has just been
  ## told it is slow, or its reply arrived and says more than that would. The
  ## request itself is untouched — only the note about it goes away.
  ##
  ## The queue is singly linked, so the predecessor has to be found by walking.
  ## It holds one entry per request that is currently slow, which is normally
  ## none. Call with `outb.lock` held.
  if not request[].staleQueued:
    return
  var prev: ptr FFIThreadRequest = nil
  var cur = outb.staleReqHead
  while not cur.isNil() and cur != request:
    prev = cur
    cur = cur[].staleNext
  if not cur.isNil():
    if prev.isNil():
      outb.staleReqHead = cur[].staleNext
    else:
      prev[].staleNext = cur[].staleNext
    if outb.staleReqTail == cur:
      # `prev` is nil when that was the only entry, which empties the queue.
      outb.staleReqTail = prev
  # Also when the walk found nothing: the flag must never outlive the link.
  request[].staleNext = nil
  request[].staleQueued = false

proc enqueueReply*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest
) {.raises: [], gcsafe.} =
  ## Queues the answered request for the host to take out of its next `poll`.
  ## FFI thread. `request` already carries its reply (`setReply`).
  request[].next = nil
  withLock outb.lock:
    # The reply says more than "still running" about the same request.
    outb.unlinkStaleReq(request)
    request[].seqNum = outb.nextSeq()
    if outb.replyReqTail.isNil():
      outb.replyReqHead = request
    else:
      outb.replyReqTail[].next = request
    outb.replyReqTail = request
  outb.notifyOutbound()

proc enqueueStaleReq*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest, elapsedMs: int64
) {.raises: [], gcsafe.} =
  ## Reports that `request` has been running for `elapsedMs`, for the host to
  ## read on its next `poll`. Called again for the same request — every
  ## `StaleWarnInterval` while it runs — it overwrites the figure instead of
  ## queueing a second report, so the host always reads the current one.
  ## FFI thread.
  withLock outb.lock:
    request[].staleElapsedMs = elapsedMs
    if request[].staleQueued:
      return
    request[].staleQueued = true
    request[].staleSeqNum = outb.nextSeq()
    request[].staleNext = nil
    if outb.staleReqTail.isNil():
      outb.staleReqHead = request
    else:
      outb.staleReqTail[].staleNext = request
    outb.staleReqTail = request
  outb.notifyOutbound()

proc replyHeadSeq*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  ## Ticket (see `nextSeq`) of the oldest queued reply, 0 when there is none.
  withLock outb.lock:
    if outb.replyReqHead.isNil():
      return 0'u64
    return outb.replyReqHead[].seqNum

proc staleHeadSeq*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  ## Ticket (see `nextSeq`) of the oldest pending stale request, 0 when none.
  withLock outb.lock:
    if outb.staleReqHead.isNil():
      return 0'u64
    return outb.staleReqHead[].staleSeqNum

proc popReply*(outb: var FFIOutbound): ptr FFIThreadRequest {.raises: [], gcsafe.} =
  ## The oldest answered request, or nil. Only the poller pops, so what
  ## `replyHeadSeq` reported cannot have gone away under it.
  withLock outb.lock:
    let request = outb.replyReqHead
    if request.isNil():
      return nil
    outb.replyReqHead = request[].next
    if outb.replyReqHead.isNil():
      outb.replyReqTail = nil
    request[].next = nil
    return request

proc popStaleReq*(
    outb: var FFIOutbound, reqId: var uint64, seqNum: var uint64, elapsedMs: var int64
): bool {.raises: [], gcsafe.} =
  ## Copies the figures out: the request itself stays with the FFI thread, which
  ## still owes a reply for it.
  withLock outb.lock:
    let request = outb.staleReqHead
    if request.isNil():
      return false
    reqId = request[].id
    seqNum = request[].staleSeqNum
    elapsedMs = request[].staleElapsedMs
    outb.unlinkStaleReq(request)
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
      replies = outb.replyReqHead
      outb.replyReqHead = nil
      outb.replyReqTail = nil
      # Every request pending here was drained or rejected by now.
      outb.staleReqHead = nil
      outb.staleReqTail = nil
    while not replies.isNil():
      let nextReply = replies[].next
      outb.retireRequest(replies)
      replies = nextReply
