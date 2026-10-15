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
  LinkKind = enum
    ReplyLink
    StaleLink

  RequestQueue* = object
    ## Requests waiting for the poller, linked through the `QueueLink` of
    ## `kind`. Guarded by `FFIOutbound.lock`.
    head, tail: ptr FFIThreadRequest
    kind: LinkKind

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
    lock*: Lock # Guards `replyQueue` and `staleQueue`.
    replyQueue*: RequestQueue # Answered requests waiting for the host.
    staleQueue*: RequestQueue # Requests running long enough to report.
    outstanding*: Atomic[int] # Submitted requests the host has not collected yet.
    reqIdSeq*: Atomic[uint64] # Request ids of this slot, over all of its owners.
    held*: HeldEvent
    heldReply*: ptr FFIThreadRequest # The reply the host reads; freed at the next poll.
    heldMsg*: array[2, PollResult]
      # What `poll` hands out. The library owns it, so appending a field to
      # `PollResult` never writes past a struct an older host allocated. Two of
      # them, used in turn: a slot outlives its owners, and the next owner's first
      # message must not land in the one the last owner is still reading.
    heldMsgSlot*: int
    watch*: HeartbeatWatch

proc link(request: ptr FFIThreadRequest, kind: LinkKind): ptr QueueLink =
  case kind
  of ReplyLink:
    return addr request[].reply
  of StaleLink:
    return addr request[].stale

proc push(q: var RequestQueue, request: ptr FFIThreadRequest, seqNum: uint64) =
  ## Appends `request`, stamped with `seqNum`. Call with `outb.lock` held.
  let l = request.link(q.kind)
  l[].next = nil
  l[].seqNum = seqNum
  l[].queued = true
  if q.tail.isNil():
    q.head = request
  else:
    q.tail.link(q.kind)[].next = request
  q.tail = request

proc headSeq(q: RequestQueue): uint64 =
  ## Ticket (see `nextSeq`) of the oldest request, 0 when there is none.
  if q.head.isNil():
    return 0'u64
  return q.head.link(q.kind)[].seqNum

proc pop(q: var RequestQueue): ptr FFIThreadRequest =
  ## The oldest request, or nil.
  let request = q.head
  if request.isNil():
    return nil
  let l = request.link(q.kind)
  q.head = l[].next
  if q.head.isNil():
    q.tail = nil
  l[].next = nil
  l[].queued = false
  return request

proc unlink(q: var RequestQueue, request: ptr FFIThreadRequest) =
  ## Takes `request` out of the queue, wherever it sits; the request itself is
  ## untouched. The queue is singly linked, so the predecessor is found by
  ## walking: the stale queue holds one entry per request that is currently
  ## slow, which is normally none.
  let l = request.link(q.kind)
  if not l[].queued:
    return
  var prev: ptr FFIThreadRequest = nil
  var cur = q.head
  while not cur.isNil() and cur != request:
    prev = cur
    cur = cur.link(q.kind)[].next
  if not cur.isNil():
    if prev.isNil():
      q.head = l[].next
    else:
      prev.link(q.kind)[].next = l[].next
    if q.tail == cur:
      # `prev` is nil when that was the only entry, which empties the queue.
      q.tail = prev
  # Also when the walk found nothing: the flag must never outlive the link.
  l[].next = nil
  l[].queued = false

proc detach(q: var RequestQueue): ptr FFIThreadRequest =
  ## Empties the queue, handing back the chain through its `QueueLink`s.
  let head = q.head
  q.head = nil
  q.tail = nil
  return head

proc initOutbound*(outb: var FFIOutbound): Result[void, string] =
  ## Idempotent: a rebuilt slot keeps its outbound (re-initLock is UB).
  if outb.ready:
    return ok()
  ?outb.wake.init()
  outb.pollLock.initLock()
  outb.lock.initLock()
  initHeldEvent(outb.held)
  outb.replyQueue.kind = ReplyLink
  outb.staleQueue.kind = StaleLink
  outb.msgSeq.store(1)
  outb.reqIdSeq.store(1)
  outb.queueLive = true
  outb.ready = true
  return ok()

proc nextSeq*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  ## Numbers a message the moment it becomes pollable: a reply when queued, a
  ## stale warning when first raised, an event when enqueued. One counter per
  ## context, so a lower number was produced earlier; `poll` returns the lowest
  ## across the three queues. Starts at 1 so a queue can report 0 for "empty".
  return outb.msgSeq.fetchAdd(1)

proc nextRequestId*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  return outb.reqIdSeq.fetchAdd(1)

proc notifyOutbound*(outb: var FFIOutbound) {.raises: [], gcsafe.} =
  ## Producer side, after an enqueue. One syscall per burst: the poller disarms, then re-checks the queues, then waits
  if not outb.wakeArmed.exchange(true):
    outb.wake.fire()

proc closeOutbound*(outb: var FFIOutbound, generation: uint) {.raises: [], gcsafe.} =
  ## Ends the messages of `generation` and wakes its poller, which then gets `RET_CLOSED`.
  outb.closedGeneration.store(generation)
  outb.wake.fire()

proc tryClaimRequest*(outb: var FFIOutbound): bool {.raises: [], gcsafe.} =
  ## Counts a submit in, or refuses it because the host is not collecting.
  if outb.outstanding.fetchAdd(1) >= MaxOutstandingRequests:
    outb.outstanding.atomicDec()
    return false
  return true

proc deleteRequest*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest
) {.raises: [], gcsafe.} =
  ## Frees a request that `tryClaimRequest` counted in: answered and collected,
  ## or dropped. The only way to free one, or the count drifts.
  if request.isNil():
    return
  freeRequest(request)
  outb.outstanding.atomicDec()

proc enqueueReply*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest
) {.raises: [], gcsafe.} =
  ## Queues the answered request for the host to take out of its next `poll`.
  ## FFI thread. `request` already carries its reply (`setReply`).
  withLock outb.lock:
    # The reply says more than "still running" about the same request.
    outb.staleQueue.unlink(request)
    outb.replyQueue.push(request, outb.nextSeq())
  outb.notifyOutbound()

proc enqueueStaleWarn*(
    outb: var FFIOutbound, request: ptr FFIThreadRequest, elapsedMs: int64
) {.raises: [], gcsafe.} =
  ## Reports that `request` has been running for `elapsedMs`, for the host to
  ## read on its next `poll`. Called again for the same request — every
  ## `StaleWarnInterval` while it runs — it overwrites the figure instead of
  ## queueing a second report, so the host always reads the current one.
  ## FFI thread.
  withLock outb.lock:
    request[].staleElapsedMs = elapsedMs
    if request[].stale.queued:
      return
    outb.staleQueue.push(request, outb.nextSeq())
  outb.notifyOutbound()

proc replyHeadSeq*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  withLock outb.lock:
    return outb.replyQueue.headSeq()

proc staleHeadSeq*(outb: var FFIOutbound): uint64 {.raises: [], gcsafe.} =
  withLock outb.lock:
    return outb.staleQueue.headSeq()

proc popRequest*(outb: var FFIOutbound): ptr FFIThreadRequest {.raises: [], gcsafe.} =
  ## The oldest answered request, or nil. Only the poller pops, so what
  ## `replyHeadSeq` reported cannot have gone away under it.
  withLock outb.lock:
    return outb.replyQueue.pop()

proc popStaleWarn*(
    outb: var FFIOutbound, reqId: var uint64, seqNum: var uint64, elapsedMs: var int64
): bool {.raises: [], gcsafe.} =
  ## Copies the figures out: the request itself stays with the FFI thread, which
  ## still owes a reply for it.
  withLock outb.lock:
    let request = outb.staleQueue.pop()
    if request.isNil():
      return false
    reqId = request[].id
    seqNum = request[].stale.seqNum
    elapsedMs = request[].staleElapsedMs
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
      replies = outb.replyQueue.detach()
      # Every request pending here was drained or rejected by now.
      discard outb.staleQueue.detach()
    while not replies.isNil():
      let nextReply = replies[].reply.next
      outb.deleteRequest(replies)
      replies = nextReply
