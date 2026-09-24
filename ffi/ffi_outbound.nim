## What a context keeps for a host that pulls its messages instead of being
## called back: the wake, the lock that makes polling single-consumer, the
## message counter and the message last handed out. Nothing here runs chronos:
## the poller is a host thread.

import std/[atomics, locks]
import results
import ./ffi_wake, ./ffi_events

type FFIOutbound* = object
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
  held*: HeldEvent

proc initOutbound*(outb: var FFIOutbound): Result[void, string] =
  ## Idempotent: a rebuilt slot keeps its outbound (re-initLock is UB).
  if outb.ready:
    return ok()
  ?outb.wake.init()
  outb.pollLock.initLock()
  initHeldEvent(outb.held)
  outb.queueLive = true
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

proc dropQueuedMessages*(
    outb: var FFIOutbound, q: var EventQueue
) {.raises: [], gcsafe.} =
  ## The next owner of the slot must not see these. Waits for a poller to leave
  ## `poll`, so call `closeOutbound` first. What the host still holds is untouched.
  withLock outb.pollLock:
    clearEventQueue(q)
