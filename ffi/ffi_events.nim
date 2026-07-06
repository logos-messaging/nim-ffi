## Per-context event registry + bounded SPSC queue. FFI thread enqueues,
## event thread drains; payloads travel via `c_malloc` so they survive
## pool-slot reuse across thread heaps.

{.pragma: callback, cdecl, raises: [], gcsafe.}

import system/ansi_c
import std/[atomics, locks, sequtils, options, tables]
import chronicles
import ./ffi_types, ./cbor_serial, ./alloc

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

proc initEventRegistry*(reg: var FFIEventRegistry) =
  ## Must run once on the owning thread before sharing — `initLock` on a
  ## live primitive is UB at the OS layer.
  reg.lock.initLock()
  reg.nextId = 0'u64
  reg.byEvent = initTable[string, seq[FFIEventListener]]()

proc deinitEventRegistry*(reg: var FFIEventRegistry) =
  ## Mirror of `initEventRegistry`; same single-thread constraint. Resets GC
  ## fields so pool-slot reuse on another thread sees no hidden dtor.
  reg.lock.deinitLock()
  reg.byEvent = default(Table[string, seq[FFIEventListener]])
  reg.nextId = 0'u64

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
  ## Safe to call from inside a dispatch — the in-flight snapshot still
  ## delivers exactly once to the removed listener.
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
  removed

proc removeAllEventListeners*(reg: var FFIEventRegistry) {.raises: [].} =
  ## Does not reset the id counter.
  withLock reg.lock:
    reg.byEvent.clear()

proc snapshotListeners*(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Lock held only across the copy — keeps re-entrant add/remove
  ## from a handler deadlock-free.
  var listeners: seq[FFIEventListener] = @[]
  withLock reg.lock:
    for l in reg.byEvent.getOrDefault(eventName):
      listeners.add(l)
  listeners

const EventQueueCapacity* {.intdefine.} = 1024
  ## Sustained backlog at this depth means a listener is wedged. Compile-time
  ## per-library override: `-d:EventQueueCapacity=N`.

const MaxEventPayloadBytes* {.intdefine.} = 512
  ## Per-slot payload slab budget. Payloads up to this size copy into a
  ## preallocated, reused buffer (zero steady-state allocation); larger ones
  ## fall back to a one-off `c_malloc` freed on commit. Compile-time
  ## per-library override: `-d:MaxEventPayloadBytes=N`.

const MaxEventNameBytes* {.intdefine.} = 64
  ## Per-slot name slab budget (incl. NUL). Event names are short compile-time
  ## literals; anything longer takes the same heap fallback as the payload.
  ## Compile-time per-library override: `-d:MaxEventNameBytes=N`.

const emptyListenerPayload*: cstring = ""
  ## Non-nil zero-length buffer handed to listeners when the payload is empty
  ## (a nil pointer would be UB for consumers doing `memcpy` even at len 0).
  ## Also the stand-in name for a nil/empty event name.

type
  QueuedEvent* = object
    # `name`/`data` point into the queue's reused per-slot buffers (not freed
    # per-event) unless the value didn't fit that slot's budget, in which case
    # the corresponding `*HeapOwned` flag marks a one-off `c_malloc` freed on
    # commit. Both buffers are `c_malloc`-backed so the event thread can read
    # them after the producing FFI thread's heap is gone (same TLS hazard as
    # `alloc.nim`).
    name*: cstring
    nameHeapOwned*: bool
    data*: ptr UncheckedArray[byte]
    dataLen*: int
    dataHeapOwned*: bool

  EventQueue* = object # SPSC ring; plain lock since ops are short and uncontended.
    lock*: Lock
    head*: int
    tail*: int
    count*: int
    buf*: array[EventQueueCapacity, QueuedEvent]
    slab*: array[EventQueueCapacity, ptr UncheckedArray[byte]] # payload buffers
    nameSlab*: array[EventQueueCapacity, ptr UncheckedArray[byte]] # name buffers

proc allocSlot(nbytes: int): ptr UncheckedArray[byte] {.raises: [].} =
  if nbytes <= 0:
    return nil
  cast[ptr UncheckedArray[byte]](c_malloc(csize_t(nbytes)))

proc initEventQueue*(q: var EventQueue) {.raises: [].} =
  q.lock.initLock()
  q.head = 0
  q.tail = 0
  q.count = 0
  for i in 0 ..< EventQueueCapacity:
    q.buf[i] = QueuedEvent()
    q.slab[i] = allocSlot(MaxEventPayloadBytes)
    q.nameSlab[i] = allocSlot(MaxEventNameBytes)

proc releaseEvent*(qe: QueuedEvent) {.raises: [], gcsafe.} =
  ## Frees only the heap-fallback buffers. Reused slot buffers persist.
  if qe.nameHeapOwned and not qe.name.isNil():
    c_free(cast[pointer](qe.name))
  if qe.dataHeapOwned and not qe.data.isNil():
    c_free(qe.data)

proc deinitEventQueue*(q: var EventQueue) {.raises: [].} =
  ## Both producer and consumer must have stopped.
  for i in 0 ..< EventQueueCapacity:
    releaseEvent(q.buf[i]) # free any undrained heap-fallback buffers
    q.buf[i] = QueuedEvent()
    if not q.slab[i].isNil():
      c_free(q.slab[i])
      q.slab[i] = nil
    if not q.nameSlab[i].isNil():
      c_free(q.nameSlab[i])
      q.nameSlab[i] = nil
  q.head = 0
  q.tail = 0
  q.count = 0
  q.lock.deinitLock()

proc copyIntoSlot(
    slot: ptr UncheckedArray[byte], slotCap, nbytes: int, src: pointer
): tuple[buf: ptr UncheckedArray[byte], heap: bool, ok: bool] {.raises: [].} =
  ## Copies `nbytes` from `src` into the reusable `slot` when they fit, else a
  ## one-off `c_malloc`. `ok=false` only on allocation failure; `nbytes<=0`
  ## yields `(nil, false, true)` with no copy.
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
    q: var EventQueue, name: cstring, src: pointer, dataLen: int
): bool {.raises: [], gcsafe.} =
  ## Copies `name` (NUL included) and `dataLen` payload bytes from `src` into
  ## the tail slot's reused buffers, or a heap fallback when either overflows
  ## its slot budget. Returns false (nothing enqueued) when the ring is full or
  ## a fallback allocation fails.
  withLock q.lock:
    if q.count >= EventQueueCapacity:
      return false
    let slot = q.tail
    # Copy the name *including* its NUL (a non-nil cstring is terminated) so the
    # stored copy stays a valid cstring; a nil/empty name uses the static stand-in.
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
        c_free(nameRes.buf) # unwind the name fallback we just took
      return false
    let nameCStr =
      if nameRes.buf.isNil():
        emptyListenerPayload
      else:
        cast[cstring](nameRes.buf)
    q.buf[slot] = QueuedEvent(
      name: nameCStr,
      nameHeapOwned: nameRes.heap,
      data: dataRes.buf,
      dataLen: dataLen,
      dataHeapOwned: dataRes.heap,
    )
    q.tail = (q.tail + 1) mod EventQueueCapacity
    q.count.inc()
  true

proc peekEvent*(q: var EventQueue): Option[QueuedEvent] {.raises: [], gcsafe.} =
  ## Returns the head event *without* advancing — the slot stays counted so the
  ## single-producer can't reuse its slab buffer while the consumer is still
  ## reading it. Pair every non-none `peekEvent` with a `commitDequeue` once
  ## dispatch has returned. The returned event borrows the slab slot.
  withLock q.lock:
    if q.count == 0:
      return none(QueuedEvent)
    return some(q.buf[q.head])

proc commitDequeue*(q: var EventQueue) {.raises: [], gcsafe.} =
  ## Retires the head slot after its `peekEvent` was dispatched: frees any
  ## heap-fallback payload, clears the slot, and only now frees it for reuse.
  withLock q.lock:
    if q.count == 0:
      return
    releaseEvent(q.buf[q.head])
    q.buf[q.head] = QueuedEvent()
    q.head = (q.head + 1) mod EventQueueCapacity
    q.count.dec()

proc eventQueueLen*(q: var EventQueue): int {.raises: [], gcsafe.} =
  withLock q.lock:
    return q.count

proc notifyListeners*(
    listeners: seq[FFIEventListener], retCode: cint, data: pointer, dataLen: int
) =
  ## Empty payloads go through `emptyListenerPayload` so consumers doing
  ## `std::string(data, len)` / `memcpy` never see a nil pointer.
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
  # Kept for tests that drive the registry directly.

var ffiCurrentEventQueue* {.threadvar.}: ptr EventQueue
  # Installed by the FFI thread so dispatch templates need no `ctx`.

var ffiCurrentEventQueueStuck* {.threadvar.}: ptr Atomic[bool]
  # Sticky overflow flag; FFI request entry point reads it to reject.

var ffiCurrentNotifyEventEnqueued* {.threadvar.}: proc() {.gcsafe, raises: [].}
  # Hook so this module doesn't depend on chronos's ThreadSignalPtr.
  # Nil-safe; tick-driven tests leave it unset.

template enqueueOrMarkStuck(eventName: string, src: pointer, dataLen: int) =
  ## Copies `eventName` and `dataLen` bytes from `src` into the queue's reused
  ## slot buffers. On queue-full sets the sticky stuck flag and wakes the event
  ## thread (firing onNotResponding from here would risk deadlock against a
  ## back-pressuring listener).
  block enqueueBlock:
    let q = ffiCurrentEventQueue
    if q.isNil():
      chronicles.error "event queue not set on this thread", event = eventName
      break enqueueBlock
    if not q[].tryEnqueueEvent(cstring(eventName), src, dataLen):
      chronicles.error "event queue full; library marked stuck",
        event = eventName, capacity = EventQueueCapacity
      if not ffiCurrentEventQueueStuck.isNil():
        ffiCurrentEventQueueStuck[].store(true)
      if not ffiCurrentNotifyEventEnqueued.isNil():
        ffiCurrentNotifyEventEnqueued()
      break enqueueBlock
    if not ffiCurrentNotifyEventEnqueued.isNil():
      ffiCurrentNotifyEventEnqueued()

template dispatchFFIEvent*(eventName: string, body: untyped) =
  ## `body` must yield `string` / `seq[byte]`. FFI thread only: copies the
  ## bytes into the tail slot (slab, or a heap fallback when oversize) and
  ## enqueues; the event thread fans out.
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
  ## Typed CBOR variant of `dispatchFFIEvent`. The param is `eventPayload`
  ## (not `payload`) to avoid clobbering `EventEnvelope.payload` substitution.
  block:
    let evtName: string = eventName
    let encoded = cborEncode(
      EventEnvelope[typeof(eventPayload)](eventType: evtName, payload: eventPayload)
    )
    let src: pointer =
      if encoded.len > 0:
        unsafeAddr encoded[0]
      else:
        nil
    enqueueOrMarkStuck(evtName, src, encoded.len)
