## Sharded, mutex-guarded MPSC ingress for `ptr FFIThreadRequest`: foreign
## threads enqueue without serialising against each other.
##
## Why sharded: one shared queue funnels all producers through a single cache
## line, capping submit throughput. N independent queues (one per producer)
## remove that hotspot — producers contend only when two pick the same queue.
##
## Each queue is an intrusive FIFO under its own `Lock`: race-free under TSAN, and
## the request is its own node (intrusive `next`), so enqueue never allocates nor
## touches a Nim GC heap (the cross-thread `MemRegion` hazard).
##
## FIFO holds per queue, not globally. Unbounded by design: submit never blocks
## or rejects; completion comes via each request's callback.

import std/[atomics, locks]
import ./ffi_thread_request

const
  RequestQueueCount* = 16
    ## Independent ingress queues. ≥ the expected concurrent producer count keeps
    ## queue collisions (hence lock contention) near zero.
  QueuePadBytes = 192
    ## Pads each queue well past a cache line (128B on Apple silicon) so adjacent
    ## queues' hot fields never false-share — false sharing would re-serialise
    ## exactly what the sharding is meant to spread out.

static:
  # `myQueueIndex` maps threads to queues with an `and` mask, so the count must
  # be a power of two — otherwise the distribution silently skews onto a subset.
  doAssert (RequestQueueCount and (RequestQueueCount - 1)) == 0,
    "RequestQueueCount must be a power of two"

type
  RequestQueue = object
    lock: Lock
    head: ptr FFIThreadRequest ## consumer pops here (oldest)
    tail: ptr FFIThreadRequest ## producers on this queue append here (newest)
    pad: array[QueuePadBytes, byte]

  FFIRequestQueue* = object
    queues: array[RequestQueueCount, RequestQueue]

var gRequestQueue {.threadvar.}: int
var gRequestQueueAssigned {.threadvar.}: bool
var gRequestQueueCounter: Atomic[int]
  ## Hands each producer thread a distinct queue round-robin on first use, so
  ## queues fill evenly regardless of OS thread-id distribution.

proc myQueueIndex(): int {.raises: [].} =
  if not gRequestQueueAssigned:
    gRequestQueue = gRequestQueueCounter.fetchAdd(1)
    gRequestQueueAssigned = true
  return gRequestQueue and (RequestQueueCount - 1) # RequestQueueCount is a power of two

proc initRequestQueue*(q: var FFIRequestQueue) {.raises: [].} =
  for queue in q.queues.mitems:
    queue.lock.initLock()
    queue.head = nil
    queue.tail = nil

proc deinitRequestQueue*(q: var FFIRequestQueue) {.raises: [].} =
  ## Both producers and the consumer must have stopped. Frees any request still
  ## queued on any queue — e.g. one a producer raced in after the FFI thread's
  ## final drain — so a teardown race leaks nothing instead of dangling them.
  for queue in q.queues.mitems:
    var request = queue.head
    while not request.isNil():
      let nextRequest = request[].next
      deleteRequest(request)
      request = nextRequest
    queue.head = nil
    queue.tail = nil
    queue.lock.deinitLock()

proc pushRequest*(
    q: var FFIRequestQueue, request: ptr FFIThreadRequest
): bool {.raises: [].} =
  ## Append `request` to this producer thread's queue (takes ownership). Returns
  ## true only when the queue was empty: the consumer sleeps on an empty queue, so
  ## that's the one push that must wake it; a missed wake just waits the 100ms poll.
  request[].next = nil
  let idx = myQueueIndex()
  withLock q.queues[idx].lock:
    let wasEmpty = q.queues[idx].tail.isNil()
    if q.queues[idx].tail.isNil():
      q.queues[idx].head = request
    else:
      q.queues[idx].tail[].next = request
    q.queues[idx].tail = request
    return wasEmpty

proc mergeQueues*(q: var FFIRequestQueue): ptr FFIThreadRequest {.raises: [].} =
  ## Single-consumer: splice every queue into one chain, resetting them to empty.
  ## Returns nil when all are empty; the caller then owns the chain and must read
  ## each request's `next` before dispatching (dispatch frees the request).
  var head: ptr FFIThreadRequest = nil
  var tail: ptr FFIThreadRequest = nil
  for queue in q.queues.mitems:
    withLock queue.lock:
      let h = queue.head
      if not h.isNil():
        if head.isNil():
          head = h
        else:
          tail[].next = h
        tail = queue.tail
        queue.head = nil
        queue.tail = nil
  return head
