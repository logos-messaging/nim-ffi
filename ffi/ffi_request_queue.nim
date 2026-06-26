## Sharded, mutex-guarded multi-producer / single-consumer ingress for
## `ptr FFIThreadRequest`. Replaces the single-slot SPSC channel plus the
## blocking accept handshake (`reqReceivedSignal.waitSync`) that made every
## foreign-thread submit serialise.
##
## Why sharded: a *single* queue — whether mutex-guarded or lock-free (Vyukov) —
## funnels every producer through one shared cache line (the lock, or the
## lock-free head). On a multicore host that one hotspot caps aggregate submit
## throughput, so it cannot scale past a single thread. Splitting the ingress
## into `RequestLaneCount` independent lanes, each picked per producer thread,
## removes the shared write point: producers contend only when two land on the
## same lane. Each lane is a plain intrusive FIFO under its own `Lock`, so the
## structure stays trivially data-race-free under TSAN with no memory-ordering
## reasoning, and the request *is* its own queue node (intrusive `next`), so
## enqueue allocates nothing and never touches a Nim GC heap (the cross-thread
## `MemRegion` hazard documented in `ffi_thread_request.nim`).
##
## Ordering: FIFO is preserved per lane, not globally. Concurrent foreign
## callers already race with no cross-thread ordering guarantee, so this is the
## same contract the single-slot channel offered in practice.
##
## Unbounded by design: the submit path must never reject or block a caller —
## completion is reported asynchronously through each request's own callback.

import std/[atomics, locks]
import ./ffi_thread_request

const
  RequestLaneCount* = 16
    ## Independent ingress lanes. ≥ the expected concurrent producer count keeps
    ## lane collisions (hence lock contention) near zero.
  LanePadBytes = 192
    ## Pads each lane well past a cache line (128B on Apple silicon) so adjacent
    ## lanes' hot fields never false-share — false sharing would re-serialise
    ## exactly what the sharding is meant to spread out.

static:
  # `myLaneIndex` maps threads to lanes with an `and` mask, so the count must be
  # a power of two — otherwise the distribution silently skews onto a subset.
  doAssert (RequestLaneCount and (RequestLaneCount - 1)) == 0,
    "RequestLaneCount must be a power of two"

type
  RequestLane = object
    lock: Lock
    head: ptr FFIThreadRequest ## consumer pops here (oldest)
    tail: ptr FFIThreadRequest ## producers on this lane append here (newest)
    count: int ## lane depth, for metrics only
    pad: array[LanePadBytes, byte]

  FFIRequestQueue* = object
    lanes: array[RequestLaneCount, RequestLane]

var gRequestLane {.threadvar.}: int
var gRequestLaneAssigned {.threadvar.}: bool
var gRequestLaneCounter: Atomic[int]
  ## Hands each producer thread a distinct lane round-robin on first use, so
  ## lanes fill evenly regardless of OS thread-id distribution.

proc myLaneIndex(): int {.raises: [].} =
  if not gRequestLaneAssigned:
    gRequestLane = gRequestLaneCounter.fetchAdd(1)
    gRequestLaneAssigned = true
  return gRequestLane and (RequestLaneCount - 1) # RequestLaneCount is a power of two

proc initRequestQueue*(q: var FFIRequestQueue) {.raises: [].} =
  for i in 0 ..< RequestLaneCount:
    q.lanes[i].lock.initLock()
    q.lanes[i].head = nil
    q.lanes[i].tail = nil
    q.lanes[i].count = 0

proc deinitRequestQueue*(q: var FFIRequestQueue) {.raises: [].} =
  ## Both producers and the consumer must have stopped. Frees any request still
  ## queued on any lane — e.g. one a producer raced in after the FFI thread's
  ## final drain — so a teardown race leaks nothing instead of dangling them.
  for i in 0 ..< RequestLaneCount:
    var node = q.lanes[i].head
    while not node.isNil:
      let nxt = node[].next
      deleteRequest(node)
      node = nxt
    q.lanes[i].head = nil
    q.lanes[i].tail = nil
    q.lanes[i].count = 0
    q.lanes[i].lock.deinitLock()

proc pushRequest*(
    q: var FFIRequestQueue, node: ptr FFIThreadRequest
): bool {.raises: [].} =
  ## Append `node` to this producer thread's lane (one O(1) critical section).
  ## The queue takes ownership. Returns true iff that lane was empty before the
  ## push — i.e. the caller should wake the consumer. When the lane was
  ## non-empty the consumer is already draining (or has a wake pending), so
  ## firing again is a wasted syscall.
  node[].next = nil
  let idx = myLaneIndex()
  withLock q.lanes[idx].lock:
    let wasEmpty = q.lanes[idx].tail.isNil
    if q.lanes[idx].tail.isNil:
      q.lanes[idx].head = node
    else:
      q.lanes[idx].tail[].next = node
    q.lanes[idx].tail = node
    q.lanes[idx].count.inc()
    return wasEmpty

proc detachAllRequests*(q: var FFIRequestQueue): ptr FFIThreadRequest {.raises: [].} =
  ## Single-consumer: splice every lane's queued chain (each lane FIFO, linked
  ## by `next`) into one chain and reset the lanes to empty, taking each lane's
  ## lock once. Returns nil when all lanes are empty; the caller then owns every
  ## request in the chain and must read each node's `next` before dispatching it
  ## (dispatch frees the node).
  var head: ptr FFIThreadRequest = nil
  var tail: ptr FFIThreadRequest = nil
  for i in 0 ..< RequestLaneCount:
    withLock q.lanes[i].lock:
      let h = q.lanes[i].head
      if not h.isNil:
        if head.isNil:
          head = h
        else:
          tail[].next = h
        tail = q.lanes[i].tail
        q.lanes[i].head = nil
        q.lanes[i].tail = nil
        q.lanes[i].count = 0
  return head

proc requestQueueLen*(q: var FFIRequestQueue): int {.raises: [].} =
  var n = 0
  for i in 0 ..< RequestLaneCount:
    withLock q.lanes[i].lock:
      n += q.lanes[i].count
  return n
