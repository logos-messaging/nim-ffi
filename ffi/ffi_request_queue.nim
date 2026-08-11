## Sharded, mutex-guarded MPSC ingress for `ptr FFIThreadRequest`: N intrusive
## FIFOs (one per producer) spread lock contention; the request is its own node
## so enqueue never touches a Nim GC heap. Bounded at `RequestQueueDepth` per
## queue — a submit never blocks, it is rejected once the queue is full.

import std/[atomics, locks]
import ./ffi_thread_request

const
  RequestQueueCount* = 16
    ## Independent ingress queues; ≥ concurrent producer count keeps collisions low.
  QueuePadBytes = 192
    ## Pads each queue past a cache line (128B on Apple silicon) to avoid false
    ## sharing between adjacent queues.

const RequestQueueDepth* {.intdefine: "ffiRequestQueueDepth".} = 1024
  ## Requests one queue holds. Caps the memory a producer that outruns the FFI
  ## thread can pin. Override with `-d:ffiRequestQueueDepth=<n>`.

static:
  # `myQueueIndex` masks with `and`, so the count must be a power of two.
  doAssert (RequestQueueCount and (RequestQueueCount - 1)) == 0,
    "RequestQueueCount must be a power of two"

type
  PushOutcome* = enum
    QueueFull ## the request still belongs to the caller
    Queued
    QueuedWake ## the queue was empty: this push must wake the consumer

  RequestQueue = object
    lock: Lock
    head: ptr FFIThreadRequest ## consumer pops here (oldest)
    tail: ptr FFIThreadRequest ## producers append here (newest)
    count: int
    pad: array[QueuePadBytes, byte]

  RequestQueueBank* = object
    queues: array[RequestQueueCount, RequestQueue]

var gRequestQueue {.threadvar.}: int
var gRequestQueueAssigned {.threadvar.}: bool
var gRequestQueueCounter: Atomic[int]
  ## Round-robins producers onto distinct queues on first use so they fill evenly.

proc myQueueIndex(): int {.raises: [].} =
  if not gRequestQueueAssigned:
    gRequestQueue = gRequestQueueCounter.fetchAdd(1)
    gRequestQueueAssigned = true
  return gRequestQueue and (RequestQueueCount - 1)

proc initRequestQueue*(bank: var RequestQueueBank) {.raises: [].} =
  for queue in bank.queues.mitems:
    queue.lock.initLock()
    queue.head = nil
    queue.tail = nil
    queue.count = 0

proc deinitRequestQueue*(bank: var RequestQueueBank) {.raises: [].} =
  ## Both producers and consumer must have stopped. Frees any still-queued request
  ## (e.g. one raced in after the final drain) so a teardown race leaks nothing.
  for queue in bank.queues.mitems:
    var request = queue.head
    while not request.isNil():
      let nextRequest = request[].next
      deleteRequest(request)
      request = nextRequest
    queue.head = nil
    queue.tail = nil
    queue.lock.deinitLock()

proc pushRequest*(
    bank: var RequestQueueBank, request: ptr FFIThreadRequest
): PushOutcome {.raises: [].} =
  ## Append `request` to this thread's queue and take ownership. On `QueueFull`
  ## the caller keeps the request.
  request[].next = nil
  let idx = myQueueIndex()
  withLock bank.queues[idx].lock:
    if bank.queues[idx].count >= RequestQueueDepth:
      return QueueFull
    let wasEmpty = bank.queues[idx].tail.isNil()
    if wasEmpty:
      bank.queues[idx].head = request
    else:
      bank.queues[idx].tail[].next = request
    bank.queues[idx].tail = request
    inc bank.queues[idx].count
    return if wasEmpty: QueuedWake else: Queued

proc mergeQueues*(bank: var RequestQueueBank): ptr FFIThreadRequest {.raises: [].} =
  ## Single-consumer: splice every queue into one chain and reset them. Caller owns
  ## the chain and must read each `next` before dispatch (dispatch frees the request).
  var head: ptr FFIThreadRequest = nil
  var tail: ptr FFIThreadRequest = nil
  for queue in bank.queues.mitems:
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
        queue.count = 0
  return head
