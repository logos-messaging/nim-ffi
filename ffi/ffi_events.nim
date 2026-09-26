## Per-context event registry + bounded SPSC queue. FFI thread enqueues, event
## thread drains; payloads use c_malloc so they survive cross-thread heap reuse.

{.pragma: callback, cdecl, raises: [], gcsafe.}

import system/ansi_c
import std/[atomics, locks, sequtils, options, tables]
import chronicles
import results
import ./ffi_types, ./cbor_serial, ./ffi_msg

type EventEnvelope*[T] = object ## CBOR wire shape: { eventType: tstr, payload: <T> }.
  eventType*: string
  payload*: T

type
  FFIEventListener* = object
    id*: uint64
    callback*: FFICallBack
    userData*: pointer

  FFIEventRegistry* = object
    lock*: Lock
    nextId*: uint64 # 0 is reserved as "invalid"; ids start at 1.
    byEvent*: Table[string, seq[FFIEventListener]]
    dispatchDone*: Cond
    dispatching*: int # deliveries in flight, over every dispatching thread.

var ffiInDispatch {.threadvar.}: int
  # Dispatch depth of this thread, so a listener never waits for its own delivery.

proc initEventRegistry*(reg: var FFIEventRegistry) =
  ## Run once on the owning thread before sharing (re-initLock is UB).
  reg.lock.initLock()
  reg.dispatchDone.initCond()
  reg.nextId = 0'u64
  reg.byEvent = initTable[string, seq[FFIEventListener]]()
  reg.dispatching = 0

proc deinitEventRegistry*(reg: var FFIEventRegistry) =
  ## Mirror of `initEventRegistry`; resets GC fields so slot reuse sees no dtor.
  reg.dispatchDone.deinitCond()
  reg.lock.deinitLock()
  reg.byEvent = default(Table[string, seq[FFIEventListener]])
  reg.nextId = 0'u64

proc awaitDispatch(reg: var FFIEventRegistry) {.raises: [].} =
  ## Call with `reg.lock` held.
  while reg.dispatching > 0 and ffiInDispatch == 0:
    wait(reg.dispatchDone, reg.lock)

proc beginDispatch*(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Snapshots the listeners of `eventName` and counts the delivery in. The
  ## caller invokes the callbacks with the lock released, and pairs every call
  ## with `endDispatch`.
  var listeners: seq[FFIEventListener] = @[]
  withLock reg.lock:
    for l in reg.byEvent.getOrDefault(eventName):
      listeners.add(l)
    reg.dispatching.inc()
  ffiInDispatch.inc()
  return listeners

proc endDispatch*(reg: var FFIEventRegistry) {.raises: [].} =
  ffiInDispatch.dec()
  withLock reg.lock:
    reg.dispatching.dec()
    broadcast(reg.dispatchDone)

proc clearListeners*(reg: var FFIEventRegistry) {.raises: [].} =
  ## Removes all listeners. The pool calls this when it recycles a context. The
  ## lock stays in place, because the event thread uses it across recycles.
  withLock reg.lock:
    reg.byEvent.clear()
    reg.nextId = 0'u64
    reg.awaitDispatch()

proc addEventListener*(
    reg: var FFIEventRegistry,
    eventName: string,
    callback: FFICallBack,
    userData: pointer,
): uint64 {.raises: [].} =
  ## Returns the listener id (>0), or 0 if `callback` is nil.
  if callback.isNil():
    return 0

  var assigned: uint64 = 0

  withLock reg.lock:
    reg.nextId.inc()
    assigned = reg.nextId
    let listener =
      FFIEventListener(id: assigned, callback: callback, userData: userData)
    reg.byEvent.mgetOrPut(eventName, @[]).add(listener)
  assigned

proc removeEventListener*(reg: var FFIEventRegistry, id: uint64): bool {.raises: [].} =
  ## Waits an in-flight delivery out, except for a caller inside a dispatch: that one returns first, so the `userData` it drops must outlive the dispatch.
  if id == 0'u64:
    return false

  var removed = false

  withLock reg.lock:
    var
      pruneKey = ""
      prune = false
    for key, listeners in reg.byEvent.mpairs:
      let before = listeners.len
      listeners.keepItIf(it.id != id)
      if listeners.len < before:
        removed = true
        if listeners.len == 0:
          pruneKey = key
          prune = true
        break
    if prune:
      reg.byEvent.del(pruneKey)
    if removed:
      reg.awaitDispatch()
  removed

proc removeAllEventListeners*(reg: var FFIEventRegistry) {.raises: [].} =
  ## Does not reset the id counter.
  withLock reg.lock:
    reg.byEvent.clear()
    reg.awaitDispatch()

proc snapshotListeners*(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Lock held only across the copy so re-entrant add/remove can't deadlock.
  var listeners: seq[FFIEventListener] = @[]
  withLock reg.lock:
    for l in reg.byEvent.getOrDefault(eventName):
      listeners.add(l)
  listeners

const EventQueueCapacity* {.intdefine: "ffiEventQueueCapacity".} = 1024
  ## Sustained backlog here means a listener is wedged. Override `-d:ffiEventQueueCapacity=N`.

const MaxEventPayloadBytes* {.intdefine: "ffiMaxEventPayloadBytes".} = 512
  ## Per-slot payload slab; larger payloads take a one-off c_malloc freed on
  ## commit. Override `-d:ffiMaxEventPayloadBytes=N`.

const MaxEventNameBytes* {.intdefine: "ffiMaxEventNameBytes".} = 64
  ## Per-slot name slab (incl. NUL); longer names take the heap fallback.
  ## Override `-d:ffiMaxEventNameBytes=N`.

const emptyListenerPayload*: cstring = ""
  ## Non-nil zero-length stand-in for empty payloads/names (nil would be UB for
  ## consumers doing memcpy even at len 0).

type
  QueuedEvent* = object
    # `name`/`data` point into reused per-slot buffers, or a one-off c_malloc marked by `*HeapOwned` when oversize; both c_malloc'd so they outlive the FFI thread's heap.
    name*: cstring
    nameHeapOwned*: bool
    nameId*: uint64 ## What a polling host matches on; the listeners use `name`.
    seq*: uint64 ## Production order within the context, 0 when nobody stamped it.
    data*: ptr UncheckedArray[byte]
    dataLen*: int
    dataHeapOwned*: bool

  EventQueue* = object
    # SPSC ring; plain lock since ops are short and uncontended.
    ## The ring itself is c_malloc'd, not inline: a context is a pool slot, and a
    ## pool held by value — as a test or a host binding does — would otherwise be
    ## megabytes of object, more than a thread's stack on Windows.
    lock*: Lock
    head*: int
    tail*: int
    count*: int
    buf*: ptr UncheckedArray[QueuedEvent]
    slab*: ptr UncheckedArray[ptr UncheckedArray[byte]]
    nameSlab*: ptr UncheckedArray[ptr UncheckedArray[byte]]

proc allocSlot(nbytes: int): ptr UncheckedArray[byte] {.raises: [].} =
  if nbytes <= 0:
    return nil
  cast[ptr UncheckedArray[byte]](c_malloc(csize_t(nbytes)))

proc allocRing[T](count: int): ptr UncheckedArray[T] {.raises: [].} =
  return cast[ptr UncheckedArray[T]](c_calloc(csize_t(count), csize_t(sizeof(T))))

proc initEventQueue*(q: var EventQueue): Result[void, string] =
  q.lock.initLock()
  q.head = 0
  q.tail = 0
  q.count = 0
  q.buf = allocRing[QueuedEvent](EventQueueCapacity)
  q.slab = allocRing[ptr UncheckedArray[byte]](EventQueueCapacity)
  q.nameSlab = allocRing[ptr UncheckedArray[byte]](EventQueueCapacity)
  if q.buf.isNil() or q.slab.isNil() or q.nameSlab.isNil():
    return err("out of memory: could not allocate the event queue")
  for i in 0 ..< EventQueueCapacity:
    q.slab[i] = allocSlot(MaxEventPayloadBytes)
    q.nameSlab[i] = allocSlot(MaxEventNameBytes)
  return ok()

proc releaseEvent*(qe: QueuedEvent) {.raises: [], gcsafe.} =
  ## Frees only heap-fallback buffers; reused slot buffers persist.
  if qe.nameHeapOwned and not qe.name.isNil():
    c_free(cast[pointer](qe.name))
  if qe.dataHeapOwned and not qe.data.isNil():
    c_free(qe.data)

proc deinitEventQueue*(q: var EventQueue) {.raises: [].} =
  ## Both producer and consumer must have stopped.
  for i in 0 ..< EventQueueCapacity:
    if not q.buf.isNil():
      releaseEvent(q.buf[i])
      q.buf[i] = QueuedEvent()
    if not q.slab.isNil() and not q.slab[i].isNil():
      c_free(q.slab[i])
      q.slab[i] = nil
    if not q.nameSlab.isNil() and not q.nameSlab[i].isNil():
      c_free(q.nameSlab[i])
      q.nameSlab[i] = nil
  if not q.buf.isNil():
    c_free(q.buf)
    q.buf = nil
  if not q.slab.isNil():
    c_free(q.slab)
    q.slab = nil
  if not q.nameSlab.isNil():
    c_free(q.nameSlab)
    q.nameSlab = nil
  q.head = 0
  q.tail = 0
  q.count = 0
  q.lock.deinitLock()

proc copyIntoSlot(
    slot: ptr UncheckedArray[byte], slotCap, nbytes: int, src: pointer
): tuple[buf: ptr UncheckedArray[byte], heap: bool, ok: bool] {.raises: [].} =
  ## Copies into `slot` when it fits, else a one-off c_malloc; `ok=false` only on
  ## alloc failure.
  if nbytes <= 0:
    return (nil, false, true)
  if nbytes <= slotCap and not slot.isNil():
    copyMem(slot, src, nbytes)
    return (slot, false, true)
  let heapBuf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(nbytes)))
  if heapBuf.isNil():
    return (nil, false, false)
  copyMem(heapBuf, src, nbytes)
  (heapBuf, true, true)

proc tryEnqueueEvent*(
    q: var EventQueue, name: cstring, nameId, seq: uint64, src: pointer, dataLen: int
): bool {.raises: [], gcsafe.} =
  ## Copies `name` (NUL included) and payload into the tail slot's reused buffers
  ## or a heap fallback; false when the ring is full or a fallback alloc fails.
  withLock q.lock:
    if q.count >= EventQueueCapacity:
      return false
    let slot = q.tail
    # Include the NUL so the stored copy stays a valid cstring.
    let nameBytes =
      if name.isNil():
        0
      else:
        name.len + 1
    let nameRes =
      copyIntoSlot(q.nameSlab[slot], MaxEventNameBytes, nameBytes, cast[pointer](name))
    if not nameRes.ok:
      return false
    let dataRes = copyIntoSlot(q.slab[slot], MaxEventPayloadBytes, dataLen, src)
    if not dataRes.ok:
      if nameRes.heap:
        c_free(nameRes.buf)
      return false
    let nameCStr =
      if nameRes.buf.isNil():
        emptyListenerPayload
      else:
        cast[cstring](nameRes.buf)
    q.buf[slot] = QueuedEvent(
      name: nameCStr,
      nameHeapOwned: nameRes.heap,
      nameId: nameId,
      seq: seq,
      data: dataRes.buf,
      dataLen: dataLen,
      dataHeapOwned: dataRes.heap,
    )
    q.tail = (q.tail + 1) mod EventQueueCapacity
    q.count.inc()
  true

proc peekEvent*(q: var EventQueue): Option[QueuedEvent] {.raises: [], gcsafe.} =
  ## Returns the head without advancing (slot stays pinned so the producer can't
  ## reuse it mid-read); pair each non-none peek with a `commitDequeue`.
  withLock q.lock:
    if q.count == 0:
      return none(QueuedEvent)
    return some(q.buf[q.head])

proc commitDequeue*(q: var EventQueue) {.raises: [], gcsafe.} =
  ## Retires the dispatched head slot: frees any heap fallback and frees the slot.
  withLock q.lock:
    if q.count == 0:
      return
    releaseEvent(q.buf[q.head])
    q.buf[q.head] = QueuedEvent()
    q.head = (q.head + 1) mod EventQueueCapacity
    q.count.dec()

type HeldEvent* = object
  ## The event a poller last handed to the host. It owns its bytes, so the ring
  ## slot is free again as soon as the event is popped.
  event*: QueuedEvent
  slab*: ptr UncheckedArray[byte]
    ## Spare payload slab: a pop swaps it with the slot's, moving the bytes out
    ## without a copy.
  nameSlab*: ptr UncheckedArray[byte] ## Spare name slab, swapped the same way.

proc initHeldEvent*(held: var HeldEvent) {.raises: [].} =
  held.event = QueuedEvent()
  held.slab = allocSlot(MaxEventPayloadBytes)
  held.nameSlab = allocSlot(MaxEventNameBytes)

proc releaseHeldEvent*(held: var HeldEvent) {.raises: [], gcsafe.} =
  ## Ends the host's use of the held bytes; the spare slabs stay.
  releaseEvent(held.event)
  held.event = QueuedEvent()

proc deinitHeldEvent*(held: var HeldEvent) {.raises: [].} =
  ## The host must be done with the message it last polled.
  releaseHeldEvent(held)
  if not held.slab.isNil():
    c_free(held.slab)
    held.slab = nil
  if not held.nameSlab.isNil():
    c_free(held.nameSlab)
    held.nameSlab = nil

proc popEventInto*(
    q: var EventQueue, held: var HeldEvent
): bool {.raises: [], gcsafe.} =
  ## Moves the head event into `held` and frees its ring slot. A payload that sat
  ## in the slot's slab changes owner by swapping slabs, so nothing is copied.
  releaseHeldEvent(held)
  withLock q.lock:
    if q.count == 0:
      return false
    let slot = q.head
    var qe = q.buf[slot]
    if not qe.dataHeapOwned and not qe.data.isNil():
      swap(q.slab[slot], held.slab)
      qe.data = held.slab
    if not qe.nameHeapOwned and not qe.name.isNil() and qe.name != emptyListenerPayload:
      swap(q.nameSlab[slot], held.nameSlab)
      qe.name = cast[cstring](held.nameSlab)
    held.event = qe
    q.buf[slot] = QueuedEvent()
    q.head = (q.head + 1) mod EventQueueCapacity
    q.count.dec()
  return true

proc headSeq*(q: var EventQueue): uint64 {.raises: [], gcsafe.} =
  ## The order mark of the oldest queued event, 0 when there is none. The poller
  ## is the only consumer, so what this returns cannot be taken from under it.
  withLock q.lock:
    if q.count == 0:
      return 0'u64
    return q.buf[q.head].seq

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

proc notifyListeners*(
    listeners: seq[FFIEventListener], retCode: cint, data: pointer, dataLen: int
) =
  ## Empty payloads use `emptyListenerPayload` so consumers never see a nil ptr.
  let n = max(dataLen, 0)
  let dataPtr =
    if n > 0 and not data.isNil():
      cast[ptr cchar](data)
    else:
      cast[ptr cchar](emptyListenerPayload)
  for listener in listeners:
    listener.callback(retCode, dataPtr, cast[csize_t](n), listener.userData)

proc notifyListenersErr*(listeners: seq[FFIEventListener], msg: string) =
  let p =
    if msg.len > 0:
      cast[pointer](unsafeAddr msg[0])
    else:
      cast[pointer](emptyListenerPayload)
  notifyListeners(listeners, RET_ERR, p, msg.len)

var ffiCurrentEventRegistry* {.threadvar.}: ptr FFIEventRegistry

var ffiCurrentEventQueue* {.threadvar.}: ptr EventQueue
  # Installed by the FFI thread so dispatch templates need no `ctx`.

var ffiCurrentEventQueueStuck* {.threadvar.}: ptr Atomic[bool]
  # Sticky overflow flag; FFI request entry point reads it to reject.

var ffiCurrentNotifyEventEnqueued* {.threadvar.}: proc() {.gcsafe, raises: [].}
  # Wake hook so this module needn't depend on chronos; nil-safe.

var ffiCurrentStampEvent* {.threadvar.}: proc(): uint64 {.gcsafe, raises: [].}
  # Gives an event its place in the context's message order; nil-safe, 0 when unset.

var ffiCurrentHostPolls* {.threadvar.}: proc(): bool {.gcsafe, raises: [].}
  # Whether anyone is collecting this context's events. Nil means someone is.

type FFIEventSink* = proc(eventName: string, payload: pointer, len: int) {.
  nimcall, gcsafe, raises: []
.}
  ## A host living in this same image, taking events on the emitting thread.

var ffiEventSink: FFIEventSink

proc setFFIEventSink*(sink: FFIEventSink) =
  ## Routes every event to `sink` instead of the queue `<lib>_poll` serves. For
  ## a library shipped inside a larger Nim program whose host has no thread
  ## of its own to poll from: the event is handed over where it is emitted,
  ## and `payload` is only valid for the call. Set before the first event.
  ffiEventSink = sink

template enqueueOrMarkStuck(eventName: string, src: pointer, dataLen: int) =
  ## Enqueues into the reused slot buffers; on queue-full sets the sticky stuck
  ## flag and wakes the event thread (firing onNotResponding here would run the
  ## listeners on the FFI thread).
  block enqueueBlock:
    if not ffiEventSink.isNil():
      ffiEventSink(eventName, src, dataLen)
      break enqueueBlock
    let q = ffiCurrentEventQueue
    if q.isNil():
      chronicles.error "event queue not set on this thread", event = eventName
      break enqueueBlock
    var seq = 0'u64
    if not ffiCurrentStampEvent.isNil():
      seq = ffiCurrentStampEvent()
    if not q[].tryEnqueueEvent(cstring(eventName), nameId(eventName), seq, src, dataLen):
      chronicles.error "event queue full; library marked stuck",
        event = eventName, capacity = EventQueueCapacity
      # A host that never collects this context's events did not ask for them:
      # dropping them is its choice, and must not wedge the library's requests.
      let collected = ffiCurrentHostPolls.isNil() or ffiCurrentHostPolls()
      if collected and not ffiCurrentEventQueueStuck.isNil():
        ffiCurrentEventQueueStuck[].store(true)
      if not ffiCurrentNotifyEventEnqueued.isNil():
        ffiCurrentNotifyEventEnqueued()
      break enqueueBlock
    if not ffiCurrentNotifyEventEnqueued.isNil():
      ffiCurrentNotifyEventEnqueued()

template dispatchFFIEvent*(eventName: string, body: untyped) =
  ## `body` yields string/seq[byte]. FFI thread only: enqueues; event thread fans out.
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
  ## Typed CBOR variant; param is `eventPayload` to avoid clobbering
  ## `EventEnvelope.payload` substitution.
  block:
    let evtName: string = eventName
    # A polling host is told which event this is by the message header, so the
    # envelope that names it for a listener would only be a wrapper to unwrap.
    let encoded =
      when defined(ffiPollMode):
        cborEncode(eventPayload)
      else:
        cborEncode(
          EventEnvelope[typeof(eventPayload)](eventType: evtName, payload: eventPayload)
        )
    let src: pointer =
      if encoded.len > 0:
        unsafeAddr encoded[0]
      else:
        nil
    enqueueOrMarkStuck(evtName, src, encoded.len)
