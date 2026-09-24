## Calls that go the other way: a handler asks the host for something and waits
## for the answer. The question is a message the host polls for, like any other;
## the answer comes back through `<lib>_reverse_reply`.
##
## Two directions, two owners. An invocation is produced by the FFI thread and
## consumed by the poller; a reply is produced by a host thread and consumed by
## the FFI thread, which is the only one that touches the pending table.

import system/ansi_c
import std/[atomics, locks, monotimes, tables]
from std/times import initDuration
import chronos
import results

const ReverseCallTimeoutMs* {.intdefine: "ffiReverseCallTimeoutMs".} = 10000
  ## How long a handler waits for the host before its call fails. A host that
  ## never polls must not park a handler for ever. Override
  ## `-d:ffiReverseCallTimeoutMs=N`.

const MaxPendingReverseCalls* {.intdefine: "ffiMaxPendingReverseCalls".} = 1024
  ## Calls waiting for the host at once, per context.

type
  ReverseCallState* {.pure.} = enum
    Queued ## waiting for the host to poll it
    Delivered ## the host has it and owes an answer
    Settled ## answered, timed out, or the context ended

  ReverseInvocation* = object ## Freed by whichever of the two sides lets go last.
    refs: Atomic[int]
    callId*: uint64
    generation*: uint
    nameId*: uint64
    seq*: uint64
    deadline*: MonoTime
    state*: Atomic[ReverseCallState]
    args*: ptr UncheckedArray[byte]
    argsLen*: int
    next*: ptr ReverseInvocation

  ReverseReply* = object
    callId*: uint64
    retCode*: cint
    data*: ptr UncheckedArray[byte]
    dataLen*: int
    next*: ptr ReverseReply

  FFIReverse* = object
    ## Lives as long as its pool slot, like the rest of the outbound state.
    ready: bool
    lock*: Lock
    nextCallId*: Atomic[uint64]
    queued*: int # invocations waiting for the host
    qHead*, qTail*: ptr ReverseInvocation
    mailbox*: ptr ReverseReply # answers the FFI thread has not drained yet
    held*: ptr ReverseInvocation # the invocation the host is reading

proc initReverse*(rev: var FFIReverse) =
  ## Idempotent: a rebuilt slot keeps it (re-initLock is UB).
  if rev.ready:
    return
  rev.lock.initLock()
  rev.ready = true

proc release*(inv: ptr ReverseInvocation) {.raises: [], gcsafe.} =
  ## The last owner frees the invocation and its arguments.
  if inv.isNil():
    return
  if inv[].refs.fetchSub(1) != 1:
    return
  if not inv[].args.isNil():
    c_free(inv[].args)
  c_free(inv)

proc newInvocation*(
    rev: var FFIReverse,
    nameId: uint64,
    generation: uint,
    args: openArray[byte],
    timeoutMs: int,
): ptr ReverseInvocation {.raises: [].} =
  ## Nil when an allocation fails; the caller reports that as a failed call.
  let inv = cast[ptr ReverseInvocation](c_malloc(csize_t(sizeof(ReverseInvocation))))
  if inv.isNil():
    return nil
  zeroMem(inv, sizeof(ReverseInvocation))
  if args.len > 0:
    let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(args.len)))
    if buf.isNil():
      c_free(inv)
      return nil
    copyMem(buf, unsafeAddr args[0], args.len)
    inv[].args = buf
    inv[].argsLen = args.len
  # Two owners from the start: the queue and the handler waiting for the answer.
  inv[].refs.store(2)
  inv[].callId = rev.nextCallId.fetchAdd(1) + 1
  inv[].generation = generation
  inv[].nameId = nameId
  inv[].deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  inv[].state.store(ReverseCallState.Queued)
  return inv

proc enqueue*(rev: var FFIReverse, inv: ptr ReverseInvocation, seq: uint64): bool =
  ## False when too many calls already wait for the host.
  withLock rev.lock:
    if rev.queued >= MaxPendingReverseCalls:
      return false
    inv[].seq = seq
    inv[].next = nil
    if rev.qTail.isNil():
      rev.qHead = inv
    else:
      rev.qTail[].next = inv
    rev.qTail = inv
    rev.queued.inc()
  return true

proc headSeq*(rev: var FFIReverse): uint64 {.raises: [], gcsafe.} =
  ## The order mark of the oldest call waiting to be handed out, 0 when none.
  withLock rev.lock:
    if rev.qHead.isNil():
      return 0'u64
    return rev.qHead[].seq

proc popForHost*(rev: var FFIReverse): ptr ReverseInvocation {.raises: [], gcsafe.} =
  ## The poller takes the oldest call. A call that was settled while it waited
  ## (timed out, or its context ended) is dropped rather than handed out.
  while true:
    var inv: ptr ReverseInvocation = nil
    withLock rev.lock:
      inv = rev.qHead
      if inv.isNil():
        return nil
      rev.qHead = inv[].next
      if rev.qHead.isNil():
        rev.qTail = nil
      rev.queued.dec()
      inv[].next = nil
    var expected = ReverseCallState.Queued
    if inv[].state.compareExchange(expected, ReverseCallState.Delivered):
      return inv
    release(inv) # the queue's reference; the waiter has let go or will

proc releaseHeld*(rev: var FFIReverse) {.raises: [], gcsafe.} =
  ## Ends the host's use of the call it last polled.
  if rev.held.isNil():
    return
  release(rev.held)
  rev.held = nil

proc pushReply*(
    rev: var FFIReverse, callId: uint64, retCode: cint, data: pointer, dataLen: int
): bool {.raises: [], gcsafe.} =
  ## Host thread. The FFI thread drains this and matches the id; an id it does
  ## not know is dropped there, so a late or forged answer costs one allocation.
  let reply = cast[ptr ReverseReply](c_malloc(csize_t(sizeof(ReverseReply))))
  if reply.isNil():
    return false
  zeroMem(reply, sizeof(ReverseReply))
  reply[].callId = callId
  reply[].retCode = retCode
  if dataLen > 0 and not data.isNil():
    let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(dataLen)))
    if buf.isNil():
      c_free(reply)
      return false
    copyMem(buf, data, dataLen)
    reply[].data = buf
    reply[].dataLen = dataLen
  withLock rev.lock:
    reply[].next = rev.mailbox
    rev.mailbox = reply
  return true

proc takeReplies*(rev: var FFIReverse): ptr ReverseReply {.raises: [], gcsafe.} =
  ## FFI thread. Takes the whole mailbox in one go.
  withLock rev.lock:
    let head = rev.mailbox
    rev.mailbox = nil
    return head

proc freeReply*(reply: ptr ReverseReply) {.raises: [], gcsafe.} =
  if reply.isNil():
    return
  if not reply[].data.isNil():
    c_free(reply[].data)
  c_free(reply)

proc dropQueuedCalls*(rev: var FFIReverse) {.raises: [], gcsafe.} =
  ## The next owner of the slot must not be handed these.
  var invs: ptr ReverseInvocation = nil
  var replies: ptr ReverseReply = nil
  withLock rev.lock:
    invs = rev.qHead
    rev.qHead = nil
    rev.qTail = nil
    rev.queued = 0
    replies = rev.mailbox
    rev.mailbox = nil
  while not invs.isNil():
    let nextInv = invs[].next
    invs[].state.store(ReverseCallState.Settled)
    release(invs)
    invs = nextInv
  while not replies.isNil():
    let nextReply = replies[].next
    freeReply(replies)
    replies = nextReply

## The FFI thread's side: one table of calls waiting for an answer.

type PendingReverse* = object
  inv*: ptr ReverseInvocation
  fut*: Future[Result[seq[byte], string]]

var ffiPendingReverse* {.threadvar.}: Table[uint64, PendingReverse]
  ## FFI thread only, so no lock: it is the only thread that completes a future.

proc rememberPending*(
    inv: ptr ReverseInvocation, fut: Future[Result[seq[byte], string]]
) =
  ffiPendingReverse[inv[].callId] = PendingReverse(inv: inv, fut: fut)

proc settle(pending: PendingReverse, res: Result[seq[byte], string]) =
  pending.inv[].state.store(ReverseCallState.Settled)
  if not pending.fut.finished():
    pending.fut.complete(res)
  release(pending.inv)

proc drainReverseReplies*(rev: var FFIReverse) =
  ## FFI thread. Answers the calls the host replied to; an id nobody waits for
  ## is dropped, which is what a late answer to a timed-out call is.
  var reply = rev.takeReplies()
  while not reply.isNil():
    let nextReply = reply[].next
    let pending = ffiPendingReverse.getOrDefault(reply[].callId)
    if not pending.inv.isNil():
      ffiPendingReverse.del(reply[].callId)
      var payload: seq[byte] = @[]
      if reply[].dataLen > 0:
        payload = newSeq[byte](reply[].dataLen)
        copyMem(addr payload[0], reply[].data, reply[].dataLen)
      var res = Result[seq[byte], string].ok(payload)
      if reply[].retCode != 0:
        var text = ""
        for i in 0 ..< reply[].dataLen:
          text.add(char(reply[].data[i]))
        if text.len == 0:
          text = "the host refused the call"
        res = Result[seq[byte], string].err(text)
      settle(pending, res)
    freeReply(reply)
    reply = nextReply

proc failOverdueReverseCalls*() =
  ## FFI thread. A host that never answers must not park a handler for ever.
  if ffiPendingReverse.len == 0:
    return
  let now = getMonoTime()
  var overdue: seq[uint64] = @[]
  for callId, pending in ffiPendingReverse:
    if now >= pending.inv[].deadline:
      overdue.add(callId)
  for callId in overdue:
    let pending = ffiPendingReverse[callId]
    ffiPendingReverse.del(callId)
    settle(pending, Result[seq[byte], string].err("the host did not answer in time"))

proc failPendingReverseCalls*(reason: string) =
  ## FFI thread, at teardown: nothing will answer these now.
  if ffiPendingReverse.len == 0:
    return
  for _, pending in ffiPendingReverse:
    settle(pending, Result[seq[byte], string].err(reason))
  ffiPendingReverse.clear()

proc callHost*(
    outbNotify: proc() {.gcsafe, raises: [].},
    rev: var FFIReverse,
    nameId: uint64,
    generation: uint,
    args: openArray[byte],
    stampSeq: proc(): uint64 {.gcsafe, raises: [].},
    timeoutMs = ReverseCallTimeoutMs,
): Future[Result[seq[byte], string]] =
  ## FFI thread. Queues the question for the host and hands back the future its
  ## answer completes. The handler awaits it like any other call.
  let fut = newFuture[Result[seq[byte], string]]("ffi.callHost")
  let inv = rev.newInvocation(nameId, generation, args, timeoutMs)
  if inv.isNil():
    fut.complete(
      Result[seq[byte], string].err("out of memory: could not queue the call")
    )
    return fut
  if not rev.enqueue(inv, stampSeq()):
    # Both references are ours: nothing else ever saw this one.
    inv[].state.store(ReverseCallState.Settled)
    release(inv)
    release(inv)
    fut.complete(
      Result[seq[byte], string].err(
        $MaxPendingReverseCalls & " calls already wait for the host"
      )
    )
    return fut
  rememberPending(inv, fut)
  outbNotify()
  return fut
