## Per-context bounded event queue. The FFI thread enqueues and the host's poller
## pops; payloads use c_malloc so they survive cross-thread heap reuse.

import system/ansi_c
import std/[atomics, locks]
import chronicles
import ./ffi_msg, ./cbor_serial

const EventQueueCapacity* {.intdefine: "ffiEventQueueCapacity".} = 1024
  ## Sustained backlog here means the host stopped polling. Override `-d:ffiEventQueueCapacity=N`.

const MaxEventPayloadBytes* {.intdefine: "ffiMaxEventPayloadBytes".} = 512
  ## Per-slot payload slab; larger payloads take a one-off c_malloc freed by the
  ## poller. Override `-d:ffiMaxEventPayloadBytes=N`.

const emptyPayload*: cstring = ""
  ## Non-nil zero-length stand-in for empty payloads (nil would be UB for
  ## consumers doing memcpy even at len 0).

type
  QueuedEvent* = object
    # `data` points into the slot's reused slab, or a one-off c_malloc marked by `dataHeapOwned` when oversize; both c_malloc'd so they outlive the FFI thread's heap.
    nameId*: uint64
    seq*: uint64
    data*: ptr UncheckedArray[byte]
    dataLen*: int
    dataHeapOwned*: bool

  EventQueue* = object # SPSC ring; plain lock since ops are short and uncontended.
    lock*: Lock
    head*: int
    tail*: int
    count*: int
    buf*: array[EventQueueCapacity, QueuedEvent]
    slab*: array[EventQueueCapacity, ptr UncheckedArray[byte]]

  HeldEvent* = object
    ## The event the poller last handed to the host. It owns its bytes, so the
    ## ring slot is free again as soon as the event is popped.
    event*: QueuedEvent
    slab*: ptr UncheckedArray[byte]
      ## Spare slab: a pop swaps it with the slot's, which moves the bytes out without a copy.

proc allocSlab(): ptr UncheckedArray[byte] {.raises: [].} =
  cast[ptr UncheckedArray[byte]](c_malloc(csize_t(MaxEventPayloadBytes)))

proc initEventQueue*(q: var EventQueue) {.raises: [].} =
  q.lock.initLock()
  q.head = 0
  q.tail = 0
  q.count = 0
  for i in 0 ..< EventQueueCapacity:
    q.buf[i] = QueuedEvent()
    q.slab[i] = allocSlab()

proc releaseEvent*(qe: QueuedEvent) {.raises: [], gcsafe.} =
  ## Frees only a heap-fallback buffer; slabs persist.
  if qe.dataHeapOwned and not qe.data.isNil():
    c_free(qe.data)

proc clearEventQueue*(q: var EventQueue) {.raises: [], gcsafe.} =
  ## Drops every queued event: the next owner of a slot must not see them.
  withLock q.lock:
    while q.count > 0:
      releaseEvent(q.buf[q.head])
      q.buf[q.head] = QueuedEvent()
      q.head = (q.head + 1) mod EventQueueCapacity
      q.count.dec()
    q.head = 0
    q.tail = 0

proc deinitEventQueue*(q: var EventQueue) {.raises: [].} =
  ## Both producer and consumer must have stopped.
  clearEventQueue(q)
  for i in 0 ..< EventQueueCapacity:
    if not q.slab[i].isNil():
      c_free(q.slab[i])
      q.slab[i] = nil
  q.lock.deinitLock()

proc initHeldEvent*(held: var HeldEvent) {.raises: [].} =
  held.event = QueuedEvent()
  held.slab = allocSlab()

proc releaseHeldEvent*(held: var HeldEvent) {.raises: [], gcsafe.} =
  ## Ends the host's use of the held bytes; the spare slab stays.
  releaseEvent(held.event)
  held.event = QueuedEvent()

proc deinitHeldEvent*(held: var HeldEvent) {.raises: [].} =
  ## The host must be done with the message it last polled.
  releaseHeldEvent(held)
  if not held.slab.isNil():
    c_free(held.slab)
    held.slab = nil

proc tryEnqueueEvent*(
    q: var EventQueue, nameId, seq: uint64, src: pointer, dataLen: int
): bool {.raises: [], gcsafe.} =
  ## Copies the payload into the tail slot's slab, or a heap fallback when it
  ## does not fit; false when the ring is full or the fallback alloc fails.
  withLock q.lock:
    if q.count >= EventQueueCapacity:
      return false
    let slot = q.tail
    var data: ptr UncheckedArray[byte] = nil
    var heapOwned = false
    if dataLen > 0:
      if dataLen <= MaxEventPayloadBytes and not q.slab[slot].isNil():
        data = q.slab[slot]
      else:
        data = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(dataLen)))
        if data.isNil():
          return false
        heapOwned = true
      copyMem(data, src, dataLen)
    q.buf[slot] = QueuedEvent(
      nameId: nameId, seq: seq, data: data, dataLen: dataLen, dataHeapOwned: heapOwned
    )
    q.tail = (q.tail + 1) mod EventQueueCapacity
    q.count.inc()
  return true

proc headSeq*(q: var EventQueue): uint64 {.raises: [], gcsafe.} =
  ## `seq` of the oldest event, or 0 when the queue is empty.
  withLock q.lock:
    if q.count == 0:
      return 0
    return q.buf[q.head].seq

proc popEventInto*(
    q: var EventQueue, held: var HeldEvent
): bool {.raises: [], gcsafe.} =
  ## Moves the oldest event into `held`, which must be released. False when empty.
  withLock q.lock:
    if q.count == 0:
      return false
    let slot = q.head
    held.event = q.buf[slot]
    if not held.event.dataHeapOwned and not held.event.data.isNil():
      swap(q.slab[slot], held.slab)
      held.event.data = held.slab
    q.buf[slot] = QueuedEvent()
    q.head = (q.head + 1) mod EventQueueCapacity
    q.count.dec()
  return true

var ffiCurrentEventQueue* {.threadvar.}: ptr EventQueue
  # Installed by the FFI thread so dispatch templates need no `ctx`.

var ffiCurrentEventQueueStuck* {.threadvar.}: ptr Atomic[bool]
  # Sticky overflow flag; FFI request entry point reads it to reject.

var ffiCurrentMsgSeq* {.threadvar.}: ptr Atomic[uint64]
  # The context's message counter, so an event takes its place among the other messages.

var ffiCurrentNotifyEventEnqueued* {.threadvar.}: proc() {.gcsafe, raises: [].}
  # Wakes the poller; a hook so this module needn't know the wake. nil-safe.

var ffiCurrentHostPolls* {.threadvar.}: proc(): bool {.gcsafe, raises: [].}
  # Whether the owner of the context has polled at all. nil reads as yes.

template enqueueOrMarkStuck(eventName: string, src: pointer, dataLen: int) =
  ## On queue-full sets the sticky stuck flag; the poller reports it.
  block enqueueBlock:
    let q = ffiCurrentEventQueue
    if q.isNil() or ffiCurrentMsgSeq.isNil():
      chronicles.error "event queue not set on this thread", event = eventName
      break enqueueBlock
    let seq = ffiCurrentMsgSeq[].fetchAdd(1) + 1
    if not q[].tryEnqueueEvent(nameId(eventName), seq, src, dataLen):
      if not ffiCurrentHostPolls.isNil() and not ffiCurrentHostPolls():
        # A host that never polls does not want events; do not fail its requests over them.
        chronicles.debug "event queue full and the host never polled; event dropped",
          event = eventName
      # Logged once: every later event of a stuck context is dropped the same way.
      elif not ffiCurrentEventQueueStuck.isNil() and
          not ffiCurrentEventQueueStuck[].exchange(true):
        chronicles.error "event queue full; library marked stuck",
          event = eventName, capacity = EventQueueCapacity
    if not ffiCurrentNotifyEventEnqueued.isNil():
      ffiCurrentNotifyEventEnqueued()

template dispatchFFIEvent*(eventName: string, body: untyped) =
  ## `body` yields string/seq[byte], sent as is. FFI thread only.
  block:
    let evtName: string = eventName
    let bodyVal = body
    let dataLen = bodyVal.len
    let src: pointer =
      if dataLen > 0:
        unsafeAddr bodyVal[0]
      else:
        nil
    enqueueOrMarkStuck(evtName, src, dataLen)

template dispatchFFIEventCbor*(eventName: string, eventPayload: typed) =
  ## Sends the bare CBOR of `eventPayload`; the name travels as `nameId`.
  block:
    let evtName: string = eventName
    let encoded = cborEncode(eventPayload)
    let src: pointer =
      if encoded.len > 0:
        unsafeAddr encoded[0]
      else:
        nil
    enqueueOrMarkStuck(evtName, src, encoded.len)
