## Event registry, bounded SPSC event queue, and dispatch templates for
## FFI library-initiated events. Listeners receive only the event name
## they subscribed to. Queue payloads travel via `c_malloc` so transfer
## across Nim heaps is safe under both `--mm:orc` and `--mm:refc`.

{.pragma: callback, cdecl, raises: [], gcsafe.}

import system/ansi_c
import std/[locks, sequtils, options, tables]
import chronicles
import ./ffi_types, ./cbor_serial


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

proc deinitEventQueue*(q: var EventQueue) {.raises: [].} =
  ## Both producer and consumer must have stopped before calling.
  for i in 0 ..< EventQueueCapacity:
    let e = q.buf[i]
    if not e.name.isNil:
      c_free(cast[pointer](e.name))
    if not e.data.isNil:
      c_free(e.data)
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


const emptyListenerPayload*: cstring = ""
  ## Non-nil zero-length buffer handed to listeners when a payload is
  ## empty, so a consumer doing `std::string(data, len)` / `memcpy` never
  ## receives a nil pointer (which is UB even at len 0).

proc notifyListeners*(
    listeners: seq[FFIEventListener], retCode: cint, data: pointer, dataLen: int
) =
  ## Fans out a payload to every listener in the snapshot. Empty payloads
  ## are delivered as the non-nil `emptyListenerPayload` sentinel so a
  ## consumer doing `std::string(data, len)` / `memcpy` never receives nil.
  let n = max(dataLen, 0)
  let dataPtr =
    if n > 0 and not data.isNil(): cast[ptr cchar](data)
    else: cast[ptr cchar](emptyListenerPayload)
  for listener in listeners:
    listener.callback(retCode, dataPtr, cast[csize_t](n), listener.userData)

proc notifyListenersErr*(listeners: seq[FFIEventListener], msg: string) =
  ## Error fan-out: adapts the message string to `notifyListeners`, which
  ## supplies the non-nil pointer for the empty-message case.
  let p =
    if msg.len > 0: cast[pointer](unsafeAddr msg[0])
    else: cast[pointer](emptyListenerPayload)
  notifyListeners(listeners, RET_ERR, p, msg.len)

var ffiCurrentEventRegistry* {.threadvar.}: ptr FFIEventRegistry
  ## Set by the FFI thread at startup so dispatchFFIEvent / dispatchFFIEventCbor
  ## can find their registry without taking a context pointer per call site.

template withFFIEventDispatch(eventName: string, listeners, body: untyped) =
  ## Shared scaffold for `dispatchFFIEvent` / `dispatchFFIEventCbor`:
  ## resolves the thread-local registry, snapshots listeners under
  ## `reg.lock` into the caller-named `listeners` binding, then runs
  ## `body` inside `foreignThreadGc` + try/except.
  let regPtr = ffiCurrentEventRegistry
  if regPtr.isNil():
    chronicles.error eventName & " - event registry not set on this thread"
    return

  withLock regPtr[].lock:
    let listeners = regPtr[].byEvent.getOrDefault(eventName)
    if listeners.len == 0:
      chronicles.debug eventName & " - no listener registered"
    else:
      foreignThreadGc:
        try:
          body
        except Exception, CatchableError:
          notifyListenersErr(
            listeners,
            "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg(),
          )

template dispatchFFIEvent*(eventName: string, body: untyped) =
  ## Dispatches an FFI event to every listener subscribed to `eventName`.
  ## `body` must yield a `string` or `seq[byte]`.
  ##
  ## Valid only on the FFI thread (where `ffiCurrentEventRegistry` is set).
  ## Holds `reg.lock` for the entire snapshot + invocation so a concurrent
  ## `removeEventListener` from a foreign thread blocks until dispatch
  ## returns. Handlers must not call addEventListener / removeEventListener
  ## on the same registry (would self-deadlock).
  withFFIEventDispatch(eventName, listeners):
    let event = body
    let dataPtr: pointer =
      if event.len > 0: cast[pointer](unsafeAddr event[0])
      else: cast[pointer](emptyListenerPayload)
    notifyListeners(listeners, RET_OK, dataPtr, event.len)

template dispatchFFIEventCbor*(eventName: string, eventPayload: typed) =
  ## Typed CBOR variant of `dispatchFFIEvent`. Wraps `eventPayload` in an
  ## `EventEnvelope`, CBOR-encodes it into a `c_malloc` buffer once, and
  ## fans the same buffer out to every registered listener.
  ##
  ## NB: parameter is `eventPayload`, not `payload` — Nim's template
  ## substitution would otherwise also rewrite the `payload:` field inside
  ## `EventEnvelope`.
  withFFIEventDispatch(eventName, listeners):
    var (data, dataLen) = cborEncodeShared(
      EventEnvelope[typeof(eventPayload)](eventType: eventName, payload: eventPayload)
    )
    defer:
      cborFreeShared(data)
    notifyListeners(listeners, RET_OK, data, dataLen)
