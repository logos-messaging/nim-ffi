## Sharded, mutex-guarded multi-producer / single-consumer ingress for
## `ptr FFIThreadRequest`. Replaces the single-slot SPSC channel plus the
## blocking accept handshake (`reqReceivedSignal.waitSync`) that made every
## foreign-thread submit serialise.
##
## Why sharded: a *single* queue — whether mutex-guarded or lock-free (Vyukov) —
## funnels every producer through one shared cache line (the lock, or the
## lock-free head). On a multicore host that one hotspot caps aggregate submit
## throughput, so it cannot scale past a single thread. Splitting the ingress
## into `RequestQueueCount` independent queues, each picked per producer thread,
## removes the shared write point: producers contend only when two land on the
## same queue. Each queue is a plain intrusive FIFO under its own `Lock`, so the
## structure stays trivially data-race-free under TSAN with no memory-ordering
## reasoning, and the request *is* its own queue node (intrusive `next`), so
## enqueue allocates nothing and never touches a Nim GC heap (the cross-thread
## `MemRegion` hazard documented in `ffi_thread_request.nim`).
##
## Ordering: FIFO is preserved per queue, not globally. Concurrent foreign
## callers already race with no cross-thread ordering guarantee, so this is the
## same contract the single-slot channel offered in practice.
##
## Unbounded by design: the submit path must never reject or block a caller —
## completion is reported asynchronously through each request's own callback.

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
  RequestShard = object
    lock: Lock
    head: ptr FFIThreadRequest ## consumer pops here (oldest)
    tail: ptr FFIThreadRequest ## producers on this queue append here (newest)
    count: int ## queue depth, for metrics only
    pad: array[QueuePadBytes, byte]

  FFIRequestQueue* = object
    queues: array[RequestQueueCount, RequestShard]

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
  for i in 0 ..< RequestQueueCount:
    q.queues[i].lock.initLock()
    q.queues[i].head = nil
    q.queues[i].tail = nil
    q.queues[i].count = 0

proc deinitRequestQueue*(q: var FFIRequestQueue) {.raises: [].} =
  ## Both producers and the consumer must have stopped. Frees any request still
  ## queued on any queue — e.g. one a producer raced in after the FFI thread's
  ## final drain — so a teardown race leaks nothing instead of dangling them.
  for i in 0 ..< RequestQueueCount:
    var node = q.queues[i].head
    while not node.isNil:
      let nxt = node[].next
      deleteRequest(node)
      node = nxt
    q.queues[i].head = nil
    q.queues[i].tail = nil
    q.queues[i].count = 0
    q.queues[i].lock.deinitLock()

proc pushRequest*(
    q: var FFIRequestQueue, node: ptr FFIThreadRequest
): bool {.raises: [].} =
  ## Append `node` to this producer thread's queue (one O(1) critical section).
  ## The queue takes ownership. Returns true iff that queue was empty before the
  ## push — i.e. the caller should wake the consumer. When the queue was
  ## non-empty the consumer is already draining (or has a wake pending), so
  ## firing again is a wasted syscall.
  node[].next = nil
  let idx = myQueueIndex()
  withLock q.queues[idx].lock:
    let wasEmpty = q.queues[idx].tail.isNil
    if q.queues[idx].tail.isNil:
      q.queues[idx].head = node
    else:
      q.queues[idx].tail[].next = node
    q.queues[idx].tail = node
    q.queues[idx].count.inc()
    return wasEmpty

proc detachAllRequests*(q: var FFIRequestQueue): ptr FFIThreadRequest {.raises: [].} =
  ## Single-consumer: splice every queue's queued chain (each queue FIFO, linked
  ## by `next`) into one chain and reset the queues to empty, taking each queue's
  ## lock once. Returns nil when all queues are empty; the caller then owns every
  ## request in the chain and must read each node's `next` before dispatching it
  ## (dispatch frees the node).
  var head: ptr FFIThreadRequest = nil
  var tail: ptr FFIThreadRequest = nil
  for i in 0 ..< RequestQueueCount:
    withLock q.queues[i].lock:
      let h = q.queues[i].head
      if not h.isNil:
        if head.isNil:
          head = h
        else:
          tail[].next = h
        tail = q.queues[i].tail
        q.queues[i].head = nil
        q.queues[i].tail = nil
        q.queues[i].count = 0
  return head

proc requestQueueLen*(q: var FFIRequestQueue): int {.raises: [].} =
  var n = 0
  for i in 0 ..< RequestQueueCount:
    withLock q.queues[i].lock:
      n += q.queues[i].count
  return n
