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

const EventQueueCapacity* = 1024
  # Sustained backlog at this depth means a listener is wedged.

type
  QueuedEvent* = object
    # Raw `c_malloc` pointers so the buffer survives pool-slot reuse
    # across thread heaps without an assignment dtor.
    name*: cstring
    data*: ptr UncheckedArray[byte]
    dataLen*: int

  EventQueue* = object # SPSC ring; plain lock since ops are short and uncontended.
    lock*: Lock
    head*: int
    tail*: int
    count*: int
    buf*: array[EventQueueCapacity, QueuedEvent]

proc initEventQueue*(q: var EventQueue) {.raises: [].} =
  q.lock.initLock()
  q.head = 0
  q.tail = 0
  q.count = 0
  for i in 0 ..< EventQueueCapacity:
    q.buf[i] = QueuedEvent(name: nil, data: nil, dataLen: 0)

proc freeEventBuffers*(
    name: cstring, data: ptr UncheckedArray[byte]
) {.raises: [], gcsafe.} =
  if not name.isNil():
    c_free(cast[pointer](name))
  if not data.isNil():
    c_free(data)

proc deinitEventQueue*(q: var EventQueue) {.raises: [].} =
  ## Both producer and consumer must have stopped.
  for i in 0 ..< EventQueueCapacity:
    freeEventBuffers(q.buf[i].name, q.buf[i].data)
    q.buf[i] = QueuedEvent(name: nil, data: nil, dataLen: 0)
  q.head = 0
  q.tail = 0
  q.count = 0
  q.lock.deinitLock()

proc tryEnqueueEvent*(
    q: var EventQueue, name: cstring, data: ptr UncheckedArray[byte], dataLen: int
): bool {.raises: [], gcsafe.} =
  ## On true the queue owns `name`/`data`; on false the caller still does.
  withLock q.lock:
    if q.count >= EventQueueCapacity:
      return false
    q.buf[q.tail] = QueuedEvent(name: name, data: data, dataLen: dataLen)
    q.tail = (q.tail + 1) mod EventQueueCapacity
    q.count.inc()
  true

proc tryDequeueEvent*(q: var EventQueue): Option[QueuedEvent] {.raises: [], gcsafe.} =
  ## Caller takes ownership and must `c_free` both buffers.
  withLock q.lock:
    if q.count == 0:
      return none(QueuedEvent)
    let dequeued = q.buf[q.head]
    q.buf[q.head] = QueuedEvent(name: nil, data: nil, dataLen: 0)
    q.head = (q.head + 1) mod EventQueueCapacity
    q.count.dec()
    return some(dequeued)

proc eventQueueLen*(q: var EventQueue): int {.raises: [], gcsafe.} =
  withLock q.lock:
    return q.count

const emptyListenerPayload*: cstring = ""
  ## Non-nil zero-length buffer handed to listeners when the payload is empty
  ## (a nil pointer would be UB for consumers doing `memcpy` even at len 0).

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

template enqueueOrMarkStuck(
    eventName: string, namePtr: cstring, dataPtr: ptr UncheckedArray[byte], dataLen: int
) =
  ## Takes ownership of `namePtr`/`dataPtr`. On queue-full sets the sticky
  ## stuck flag and wakes the event thread (firing onNotResponding from here
  ## would risk deadlock against a back-pressuring listener).
  block enqueueBlock:
    let q = ffiCurrentEventQueue
    if q.isNil():
      chronicles.error "event queue not set on this thread", event = eventName
      freeEventBuffers(namePtr, dataPtr)
      break enqueueBlock
    if not q[].tryEnqueueEvent(namePtr, dataPtr, dataLen):
      chronicles.error "event queue full; library marked stuck",
        event = eventName, capacity = EventQueueCapacity
      freeEventBuffers(namePtr, dataPtr)
      if not ffiCurrentEventQueueStuck.isNil():
        ffiCurrentEventQueueStuck[].store(true)
      if not ffiCurrentNotifyEventEnqueued.isNil():
        ffiCurrentNotifyEventEnqueued()
      break enqueueBlock
    if not ffiCurrentNotifyEventEnqueued.isNil():
      ffiCurrentNotifyEventEnqueued()

  ## `body` must yield `string` / `seq[byte]`. FFI thread only: encodes into
  ## a `c_malloc` buffer and enqueues; the event thread fans out to listeners.
  block:
    let evtName: string = eventName
    let bodyVal = body
    var dataPtr: ptr UncheckedArray[byte] = nil
    let dataLen = bodyVal.len
    if dataLen > 0:
      dataPtr = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(dataLen)))
      copyMem(dataPtr, unsafeAddr bodyVal[0], dataLen)
    let namePtr = alloc(evtName)
    enqueueOrMarkStuck(evtName, namePtr, dataPtr, dataLen)

template dispatchFFIEventCbor*(eventName: string, eventPayload: typed) =
  ## Typed CBOR variant of `dispatchFFIEvent`. The param is `eventPayload`
  ## (not `payload`) to avoid clobbering `EventEnvelope.payload` substitution.
  block:
    let evtName: string = eventName
    var (dataPtr, dataLen) = cborEncodeShared(
      EventEnvelope[typeof(eventPayload)](eventType: evtName, payload: eventPayload)
    )
    let namePtr = alloc(evtName)
    enqueueOrMarkStuck(evtName, namePtr, dataPtr, dataLen)
