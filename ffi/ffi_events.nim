## Event registry, bounded SPSC event queue, and dispatch templates for
## FFI library-initiated events. Listeners receive only the event name
## they subscribed to. Queue payloads travel via `c_malloc` so transfer
## across Nim heaps is safe under both `--mm:orc` and `--mm:refc`.
##
## Dispatch templates enqueue and return on the FFI thread; a dedicated
## event thread (owned by `FFIContext`) drains the queue and invokes
## listeners, so a slow handler can never block the FFI event loop. On
## queue overflow the templates log, set a sticky stuck flag, and wake
## the event thread — which fires the global "not responding"
## notification from its own loop (firing it from the FFI thread would
## risk deadlocking against a listener back-pressuring under `reg.lock`).

{.pragma: callback, cdecl, raises: [], gcsafe.}

import system/ansi_c
import std/[atomics, locks, sequtils, options, tables]
import chronicles
import ./ffi_types, ./cbor_serial, ./alloc


type EventEnvelope*[T] = object
  ## Standard wire shape for CBOR-encoded FFI events:
  ##   { eventType: tstr, payload: <T> }
  ## Pair with `dispatchFFIEventCbor` (or call `cborEncode` directly).
  eventType*: string
  payload*: T


type
  FFIEventListener* = object
    id*: uint64
    callback*: FFICallBack
    userData*: pointer

  FFIEventRegistry* = object
    ## Per-context multi-listener registry. `lock` guards every mutation;
    ## readers (dispatch path) acquire it only long enough to copy out the
    ## listener slice for the event being dispatched.
    lock*: Lock
    nextId*: uint64 ## Monotonic id source. 0 is reserved as "invalid"; ids start at 1.
    byEvent*: Table[string, seq[FFIEventListener]]


proc initEventRegistry*(reg: var FFIEventRegistry) =
  ## Must be called exactly once on the owning thread before the registry
  ## is shared. The embedded `Lock` wraps a platform primitive that cannot
  ## be safely double-initialised, so concurrent callers would hit UB at
  ## the OS layer — the lock itself can't defend against its own init.
  reg.lock.initLock()
  reg.nextId = 0'u64
  reg.byEvent = initTable[string, seq[FFIEventListener]]()

proc deinitEventRegistry*(reg: var FFIEventRegistry) =
  ## Mirror of `initEventRegistry`: must be called exactly once, by the
  ## same thread that owns the registry, after all other threads have
  ## stopped using it. `deinitLock` on a platform primitive that any
  ## thread might still be holding or about to acquire is UB at the OS
  ## layer.
  ##
  ## Resets the GC-managed fields to default so `FFIContextPool`'s
  ## slot reuse on a *different* thread doesn't trigger Nim's hidden
  ## assignment destructor against this thread's heap allocations.
  reg.lock.deinitLock()
  reg.byEvent = default(Table[string, seq[FFIEventListener]])
  reg.nextId = 0'u64

proc addEventListener*(
    reg: var FFIEventRegistry,
    eventName: string,
    callback: FFICallBack,
    userData: pointer,
): uint64 {.raises: [].} =
  ## Registers `callback` for `eventName` and returns the listener's stable
  ## id (always non-zero on success). A listener only receives events
  ## dispatched under its own `eventName` — subscribe to each event
  ## separately. Returns 0 if `callback` is nil — the only documented
  ## failure mode.
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
  ## Removes the listener with `id`. Returns true on success, false if no
  ## listener with that id exists. Safe to call from inside a dispatch:
  ## the in-flight snapshot still delivers exactly once to the listener
  ## being removed.
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
  ## Drops every registered listener. Does not reset the listener-id
  ## counter — subsequent `addEventListener` calls still return strictly
  ## increasing ids.
  withLock reg.lock:
    reg.byEvent.clear()

proc snapshotListeners*(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Returns a copy of the listener slice for `eventName`. The copy is what
  ## makes re-entrant add/remove from inside a handler deadlock-free:
  ## dispatch holds the lock only for the duration of the copy, then
  ## iterates the copy outside the lock.
  var listeners: seq[FFIEventListener] = @[]
  withLock reg.lock:
    # `getOrDefault` avoids the raising `[]` path; returns empty when absent.
    for l in reg.byEvent.getOrDefault(eventName):
      listeners.add(l)
  listeners


const EventQueueCapacity* = 1024
  ## ~24 KiB per context. Sustained backlog at this depth means a
  ## listener is wedged — what the stuck flag exists to surface.

type
  QueuedEvent* = object
    ## All fields are raw `c_malloc` pointers so the buffer survives
    ## pool-slot reuse across thread heaps without an assignment dtor.
    name*: cstring
    data*: ptr UncheckedArray[byte]
    dataLen*: int

  EventQueue* = object
    ## SPSC ring: FFI thread enqueues, event thread dequeues. Plain lock
    ## (no atomic indices) — operations are short and uncontended.
    lock*: Lock
    head*: int
    tail*: int
    count*: int
    buf*: array[EventQueueCapacity, QueuedEvent]

proc initEventQueue*(q: var EventQueue) {.raises: [].} =
  ## Same single-owning-thread constraint as `initEventRegistry`.
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
  ## Both producer and consumer must have stopped before calling.
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
  ## Both `name` and `data` must be `c_malloc`'d; on success the queue
  ## takes ownership. On false the caller still owns and must free them.
  withLock q.lock:
    if q.count >= EventQueueCapacity:
      return false
    q.buf[q.tail] = QueuedEvent(name: name, data: data, dataLen: dataLen)
    q.tail = (q.tail + 1) mod EventQueueCapacity
    q.count.inc()
  true

proc tryDequeueEvent*(q: var EventQueue): Option[QueuedEvent] {.raises: [], gcsafe.} =
  ## Transfers buffer ownership to the caller, who must `c_free` both.
  withLock q.lock:
    if q.count == 0:
      return none(QueuedEvent)
    let e = q.buf[q.head]
    q.buf[q.head] = QueuedEvent(name: nil, data: nil, dataLen: 0)
    q.head = (q.head + 1) mod EventQueueCapacity
    q.count.dec()
    return some(e)

proc eventQueueLen*(q: var EventQueue): int {.raises: [], gcsafe.} =
  withLock q.lock:
    return q.count


proc notifyListenersOk*(
    listeners: seq[FFIEventListener], data: pointer, dataLen: int
) =
  ## Fans out a successful payload to every listener in the snapshot.
  let dataPtr =
    if dataLen > 0: cast[ptr cchar](data)
    else: nil
  for listener in listeners:
    listener.callback(
      RET_OK, dataPtr, cast[csize_t](dataLen), listener.userData
    )

proc notifyListenersErr*(listeners: seq[FFIEventListener], msg: string) =
  ## Fans out an error message to every listener in the snapshot.
  let dataPtr =
    if msg.len > 0: cast[ptr cchar](unsafeAddr msg[0])
    else: nil
  for listener in listeners:
    listener.callback(
      RET_ERR, dataPtr, cast[csize_t](msg.len), listener.userData
    )

var ffiCurrentEventRegistry* {.threadvar.}: ptr FFIEventRegistry
  ## Kept for tests that drive the registry directly. Dispatch no longer
  ## reads it — invocation has moved to the event thread.

var ffiCurrentEventQueue* {.threadvar.}: ptr EventQueue
  ## Installed by the FFI thread so dispatch templates enqueue without
  ## threading a `ctx` parameter through every call site.

var ffiCurrentEventQueueStuck* {.threadvar.}: ptr Atomic[bool]
  ## Sticky overflow flag on the owning `FFIContext`. Set by dispatch
  ## templates when enqueue fails; read by the FFI request entry point
  ## to reject further calls.

var ffiCurrentNotifyEventEnqueued* {.threadvar.}: proc() {.gcsafe, raises: [].}
  ## Hook (not a queue field) so this module doesn't depend on chronos's
  ## ThreadSignalPtr. Nil-safe — tests that drive the queue directly leave
  ## it unset and the event thread picks up enqueued events on the next tick.

template enqueueOrMarkStuck(
    eventName: string,
    namePtr: cstring,
    dataPtr: ptr UncheckedArray[byte],
    dataLen: int,
) =
  ## Common tail for both dispatch templates. Takes ownership of `namePtr`
  ## and `dataPtr` (both `c_malloc`'d). On queue-full, frees the buffers,
  ## sets the sticky stuck flag, and wakes the event thread — which fires
  ## onNotResponding from its loop (firing it here would risk deadlocking
  ## against a listener back-pressuring under `reg.lock`).
  let q = ffiCurrentEventQueue
  if q.isNil():
    chronicles.error "event queue not set on this thread", event = eventName
    freeEventBuffers(namePtr, dataPtr)
  elif not q[].tryEnqueueEvent(namePtr, dataPtr, dataLen):
    chronicles.error "event queue full; library marked stuck",
      event = eventName, capacity = EventQueueCapacity
    freeEventBuffers(namePtr, dataPtr)
    if not ffiCurrentEventQueueStuck.isNil():
      ffiCurrentEventQueueStuck[].store(true)
    if not ffiCurrentNotifyEventEnqueued.isNil():
      ffiCurrentNotifyEventEnqueued()
  else:
    if not ffiCurrentNotifyEventEnqueued.isNil():
      ffiCurrentNotifyEventEnqueued()

template dispatchFFIEvent*(eventName: string, body: untyped) =
  ## Dispatches an FFI event to every listener subscribed to `eventName`.
  ## `body` must yield a `string` or `seq[byte]`.
  ##
  ## Runs on the FFI thread: encodes the body into a fresh `c_malloc`
  ## buffer and enqueues it. Listener invocation happens later on the
  ## dedicated event thread, so user code can never block the FFI loop.
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
  ## Typed CBOR variant of `dispatchFFIEvent`. Wraps `eventPayload` in an
  ## `EventEnvelope`, CBOR-encodes it into a `c_malloc` buffer once, and
  ## queues it for the event thread to fan out to listeners.
  ##
  ## NB: parameter is `eventPayload`, not `payload` — Nim's template
  ## substitution would otherwise also rewrite the `payload:` field inside
  ## `EventEnvelope`.
  block:
    let evtName: string = eventName
    var (dataPtr, dataLen) = cborEncodeShared(
      EventEnvelope[typeof(eventPayload)](eventType: evtName, payload: eventPayload)
    )
    let namePtr = alloc(evtName)
    enqueueOrMarkStuck(evtName, namePtr, dataPtr, dataLen)
