## Per-context event registry + bounded SPSC queue. FFI thread enqueues, event
## thread drains; payloads use c_malloc so they survive cross-thread heap reuse.

{.pragma: callback, cdecl, raises: [], gcsafe.}

import system/ansi_c
import std/[atomics, locks, options]
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

  RegisteredListener = object
    nameId: uint64
    listener: FFIEventListener

  FFIEventRegistry* = object
    lock*: Lock
    nextId*: uint64 # 0 is reserved as "invalid"; ids start at 1.
    # c_malloc'd: host threads add and remove, and a GC block freed after its thread exits faults.
    entries: ptr UncheckedArray[RegisteredListener]
    len: int
    cap: int
    dispatchDone*: Cond
    dispatching*: int # deliveries in flight, over every dispatching thread.

var ffiInDispatch {.threadvar.}: int
  # Dispatch depth of this thread, so a listener never waits for its own delivery.

var ffiDispatchRegistry {.threadvar.}: ptr FFIEventRegistry
  # The registry this thread dispatches; a remove on another context's registry still waits.

proc initEventRegistry*(reg: var FFIEventRegistry) =
  ## Run once on the owning thread before sharing (re-initLock is UB).
  reg.lock.initLock()
  reg.dispatchDone.initCond()
  reg.nextId = 0'u64
  reg.entries = nil
  reg.len = 0
  reg.cap = 0
  reg.dispatching = 0

proc deinitEventRegistry*(reg: var FFIEventRegistry) =
  ## Mirror of `initEventRegistry`.
  reg.dispatchDone.deinitCond()
  reg.lock.deinitLock()
  if not reg.entries.isNil():
    c_free(reg.entries)
  reg.entries = nil
  reg.len = 0
  reg.cap = 0
  reg.nextId = 0'u64

proc listenersOf(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Call with `reg.lock` held.
  let id = nameId(eventName)
  var listeners: seq[FFIEventListener] = @[]
  for i in 0 ..< reg.len:
    if reg.entries[i].nameId == id:
      listeners.add(reg.entries[i].listener)
  return listeners

proc grow(reg: var FFIEventRegistry): bool {.raises: [].} =
  ## Call with `reg.lock` held; false when out of memory.
  let newCap = max(8, reg.cap * 2)
  let p = c_realloc(reg.entries, csize_t(newCap * sizeof(RegisteredListener)))
  if p.isNil():
    return false
  reg.entries = cast[ptr UncheckedArray[RegisteredListener]](p)
  reg.cap = newCap
  return true

proc awaitDispatch(reg: var FFIEventRegistry) {.raises: [].} =
  ## Call with `reg.lock` held.
  let ownDelivery = ffiInDispatch > 0 and ffiDispatchRegistry == addr reg
  while reg.dispatching > 0 and not ownDelivery:
    wait(reg.dispatchDone, reg.lock)

proc beginDispatch*(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Snapshots the listeners of `eventName` and counts the delivery in. The
  ## caller invokes the callbacks with the lock released, and pairs every call
  ## with `endDispatch`.
  var listeners: seq[FFIEventListener] = @[]
  withLock reg.lock:
    listeners = reg.listenersOf(eventName)
    reg.dispatching.inc()
  ffiInDispatch.inc()
  ffiDispatchRegistry = addr reg
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
    reg.len = 0
    reg.nextId = 0'u64
    reg.awaitDispatch()

proc addEventListener*(
    reg: var FFIEventRegistry,
    eventName: string,
    callback: FFICallBack,
    userData: pointer,
): uint64 {.raises: [].} =
  ## Returns the listener id (>0), or 0 if `callback` is nil or memory runs out.
  if callback.isNil():
    return 0

  var assigned: uint64 = 0

  withLock reg.lock:
    if reg.len == reg.cap and not reg.grow():
      return 0
    reg.nextId.inc()
    assigned = reg.nextId
    reg.entries[reg.len] = RegisteredListener(
      nameId: nameId(eventName),
      listener: FFIEventListener(id: assigned, callback: callback, userData: userData),
    )
    reg.len.inc()
  assigned

proc removeEventListener*(reg: var FFIEventRegistry, id: uint64): bool {.raises: [].} =
  ## Waits an in-flight delivery out, except from inside a dispatch, which then skips the removed listener.
  if id == 0'u64:
    return false

  var removed = false

  withLock reg.lock:
    for i in 0 ..< reg.len:
      if reg.entries[i].listener.id == id:
        moveMem(
          addr reg.entries[i],
          addr reg.entries[i + 1],
          (reg.len - i - 1) * sizeof(RegisteredListener),
        )
        reg.len.dec()
        removed = true
        break
    if removed:
      reg.awaitDispatch()
  removed

proc removeAllEventListeners*(reg: var FFIEventRegistry) {.raises: [].} =
  ## Does not reset the id counter.
  withLock reg.lock:
    reg.len = 0
    reg.awaitDispatch()

proc snapshotListeners*(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Lock held only across the copy so re-entrant add/remove can't deadlock.
  withLock reg.lock:
    return reg.listenersOf(eventName)

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
    nameId*: uint64
    seqNum*: uint64
      ## Production order within the context; 0 when none was assigned (callback mode).
    data*: ptr UncheckedArray[byte]
    dataLen*: int
    dataHeapOwned*: bool

  EventQueue* = object # SPSC ring; plain lock since ops are short and uncontended.
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
    q: var EventQueue, name: cstring, nameId, seqNum: uint64, src: pointer, dataLen: int
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
      seqNum: seqNum,
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
  nameSlab*: ptr UncheckedArray[byte]

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
    if cast[pointer](qe.data) == cast[pointer](q.slab[slot]) and not qe.data.isNil():
      swap(q.slab[slot], held.slab)
      qe.data = held.slab
    if cast[pointer](qe.name) == cast[pointer](q.nameSlab[slot]) and not qe.name.isNil():
      swap(q.nameSlab[slot], held.nameSlab)
      qe.name = cast[cstring](held.nameSlab)
    held.event = qe
    q.buf[slot] = QueuedEvent()
    q.head = (q.head + 1) mod EventQueueCapacity
    q.count.dec()
  return true

proc hasEvents*(q: var EventQueue): bool {.raises: [], gcsafe.} =
  withLock q.lock:
    return q.count > 0

proc headSeq*(q: var EventQueue): uint64 {.raises: [], gcsafe.} =
  ## The order mark of the oldest queued event, 0 when there is none. The poller
  ## is the only consumer, so what this returns cannot be taken from under it.
  withLock q.lock:
    if q.count == 0:
      return 0'u64
    return q.buf[q.head].seqNum

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

proc isRegistered(
    reg: var FFIEventRegistry, eventName: string, id: uint64
): bool {.raises: [].} =
  let nid = nameId(eventName)
  withLock reg.lock:
    for i in 0 ..< reg.len:
      if reg.entries[i].listener.id == id:
        return reg.entries[i].nameId == nid
  return false

proc notifyListeners*(
    reg: var FFIEventRegistry,
    eventName: string,
    listeners: openArray[FFIEventListener],
    retCode: cint,
    data: pointer,
    dataLen: int,
) =
  ## Calls each listener still registered; an empty payload goes out as `emptyListenerPayload`, never nil.
  let n = max(dataLen, 0)
  let dataPtr =
    if n > 0 and not data.isNil():
      cast[ptr cchar](data)
    else:
      cast[ptr cchar](emptyListenerPayload)
  for listener in listeners:
    if not reg.isRegistered(eventName, listener.id):
      continue
    listener.callback(retCode, dataPtr, cast[csize_t](n), listener.userData)

proc notifyListenersErr*(
    reg: var FFIEventRegistry,
    eventName: string,
    listeners: openArray[FFIEventListener],
    msg: string,
) =
  let p =
    if msg.len > 0:
      cast[pointer](unsafeAddr msg[0])
    else:
      cast[pointer](emptyListenerPayload)
  reg.notifyListeners(eventName, listeners, RET_ERR, p, msg.len)

var ffiCurrentEventRegistry* {.threadvar.}: ptr FFIEventRegistry

var ffiCurrentEventQueue* {.threadvar.}: ptr EventQueue
  # Installed by the FFI thread so dispatch templates need no `ctx`.

var ffiCurrentEventQueueStuck* {.threadvar.}: ptr Atomic[bool]
  # Sticky overflow flag; FFI request entry point reads it to reject.

var ffiCurrentNotifyEventEnqueued* {.threadvar.}: proc() {.gcsafe, raises: [].}
  # Wake hook so this module needn't depend on chronos; nil-safe.

var ffiNextEventSeqNum* {.threadvar.}: proc(): uint64 {.gcsafe, raises: [].}
  # Gives an event its place in the context's message order; nil-safe, 0 when unset.

var ffiCurrentHostPolls* {.threadvar.}: proc(): bool {.gcsafe, raises: [].}
  # Whether anyone is collecting this context's events. Nil means someone is.

var ffiEventDropLogged {.threadvar.}: bool
  # A full queue stays full for every event that follows; log the first drop only.

template enqueueOrMarkStuck(eventName: string, src: pointer, dataLen: int) =
  ## Enqueues into the reused slot buffers; on queue-full sets the sticky stuck
  ## flag and wakes the event thread (firing onNotResponding here would run the
  ## listeners on the FFI thread).
  block enqueueBlock:
    let q = ffiCurrentEventQueue
    if q.isNil():
      chronicles.error "event queue not set on this thread", event = eventName
      break enqueueBlock
    var seqNum = 0'u64
    if not ffiNextEventSeqNum.isNil():
      seqNum = ffiNextEventSeqNum()
    if not q[].tryEnqueueEvent(
      cstring(eventName), nameId(eventName), seqNum, src, dataLen
    ):
      if not ffiEventDropLogged:
        ffiEventDropLogged = true
        chronicles.error "event queue full; dropping events until it drains",
          event = eventName, capacity = EventQueueCapacity
      # A host that never collects this context's events did not ask for them:
      # dropping them is its choice, and must not wedge the library's requests.
      let collected = ffiCurrentHostPolls.isNil() or ffiCurrentHostPolls()
      if collected and not ffiCurrentEventQueueStuck.isNil():
        ffiCurrentEventQueueStuck[].store(true)
      if not ffiCurrentNotifyEventEnqueued.isNil():
        ffiCurrentNotifyEventEnqueued()
      break enqueueBlock
    ffiEventDropLogged = false
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
