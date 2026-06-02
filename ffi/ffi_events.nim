## Event registry, bounded SPSC event queue, and dispatch templates for
## FFI library-initiated events. Empty event name `""` registers a
## wildcard listener that receives every dispatched event. Queue
## payloads travel via `c_malloc` so transfer across Nim heaps is safe
## under both `--mm:orc` and `--mm:refc`.

{.pragma: callback, cdecl, raises: [], gcsafe.}

import system/ansi_c
import std/[atomics, locks, options, tables]
import chronicles
import ./ffi_types, ./cbor_serial

# ---------------------------------------------------------------------------
# Wire envelope
# ---------------------------------------------------------------------------

type EventEnvelope*[T] = object
  ## Standard wire shape for CBOR-encoded FFI events:
  ##   { eventType: tstr, payload: <T> }
  ## Pair with `dispatchFFIEventCbor` (or call `cborEncode` directly).
  eventType*: string
  payload*: T

# ---------------------------------------------------------------------------
# Registry types
# ---------------------------------------------------------------------------

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
    wildcard*: seq[FFIEventListener]

const WildcardEventName* = ""
  ## Empty string registers a wildcard listener that receives every event.

# ---------------------------------------------------------------------------
# Registry lifecycle and mutation
# ---------------------------------------------------------------------------

proc initEventRegistry*(reg: var FFIEventRegistry) =
  ## Must be called exactly once on the owning thread before the registry
  ## is shared. The embedded `Lock` wraps a platform primitive that cannot
  ## be safely double-initialised, so concurrent callers would hit UB at
  ## the OS layer — the lock itself can't defend against its own init.
  reg.lock.initLock()
  reg.nextId = 0'u64
  reg.byEvent = initTable[string, seq[FFIEventListener]]()
  reg.wildcard.setLen(0)

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
  reg.wildcard = @[]
  reg.nextId = 0'u64

proc addEventListener*(
    reg: var FFIEventRegistry,
    eventName: string,
    callback: FFICallBack,
    userData: pointer,
): uint64 {.raises: [].} =
  ## Registers `callback` for `eventName` and returns the listener's stable
  ## id (always non-zero on success). `eventName == ""` registers a wildcard
  ## listener that receives every dispatched event. Returns 0 if `callback`
  ## is nil — the only documented failure mode.
  if callback.isNil():
    return 0

  var assigned: uint64 = 0

  withLock reg.lock:
    reg.nextId.inc()
    assigned = reg.nextId
    let listener =
      FFIEventListener(id: assigned, callback: callback, userData: userData)
    if eventName.len == 0:
      reg.wildcard.add(listener)
    else:
      reg.byEvent.mgetOrPut(eventName, @[]).add(listener)
  return assigned

proc removeEventListener*(reg: var FFIEventRegistry, id: uint64): bool {.raises: [].} =
  ## Removes the listener with `id`. Returns true on success, false if no
  ## listener with that id exists. Safe to call from inside a dispatch:
  ## the in-flight snapshot still delivers exactly once to the listener
  ## being removed.
  if id == 0'u64:
    return false

  var removed = false

  withLock reg.lock:
    for i in 0 ..< reg.wildcard.len:
      if reg.wildcard[i].id == id:
        reg.wildcard.delete(i)
        removed = true
        break
    if not removed:
      var emptyKey = ""
      var prune = false
      for key, listeners in reg.byEvent.mpairs:
        var idx = -1
        for i in 0 ..< listeners.len:
          if listeners[i].id == id:
            idx = i
            break
        if idx >= 0:
          listeners.delete(idx)
          removed = true
          if listeners.len == 0:
            emptyKey = key
            prune = true
          break
      if prune:
        reg.byEvent.del(emptyKey)
  return removed

proc removeAllEventListeners*(reg: var FFIEventRegistry) {.raises: [].} =
  ## Drops every registered listener (per-event and wildcard). Does not
  ## reset the listener-id counter — subsequent `addEventListener` calls
  ## still return strictly increasing ids.
  withLock reg.lock:
    reg.wildcard.setLen(0)
    reg.byEvent.clear()

proc snapshotListeners*(
    reg: var FFIEventRegistry, eventName: string
): seq[FFIEventListener] {.raises: [].} =
  ## Returns a copy of the listener slice for `eventName`, plus every
  ## wildcard listener. The copy is what makes re-entrant add/remove from
  ## inside a handler deadlock-free: dispatch holds the lock only for the
  ## duration of the copy, then iterates the copy outside the lock.
  var snap: seq[FFIEventListener] = @[]
  withLock reg.lock:
    if eventName.len > 0:
      # `getOrDefault` returns an empty seq when the key is absent —
      # avoids the raising `[]` operator path.
      for l in reg.byEvent.getOrDefault(eventName):
        snap.add(l)
    for l in reg.wildcard:
      snap.add(l)
  return snap

# ---------------------------------------------------------------------------
# Bounded event queue
# ---------------------------------------------------------------------------

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
  return true

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

# ---------------------------------------------------------------------------
# Dispatch templates (used by {.ffiEvent.}-generated procs)
# ---------------------------------------------------------------------------

var ffiCurrentEventRegistry* {.threadvar.}: ptr FFIEventRegistry
var ffiCurrentEventQueue* {.threadvar.}: ptr EventQueue
var ffiCurrentEventQueueStuck* {.threadvar.}: ptr Atomic[bool]
var ffiCurrentNotifyEventEnqueued* {.threadvar.}: proc() {.gcsafe, raises: [].}
  ## Hook (not a queue field) so this module doesn't depend on chronos's
  ## ThreadSignalPtr. Nil-safe.

template withFFIEventDispatch(eventName: string, listeners, body: untyped) =
  ## Resolves the thread-local registry, snapshots listeners under
  ## `reg.lock`, then runs `body` inside `foreignThreadGc` + try/except.
  let regPtr = ffiCurrentEventRegistry
  if regPtr.isNil():
    chronicles.error eventName & " - event registry not set on this thread"
    return

  withLock regPtr[].lock:
    let listeners = regPtr[].byEvent.getOrDefault(eventName) & regPtr[].wildcard
    if listeners.len == 0:
      chronicles.debug eventName & " - no listener registered"
    else:
      foreignThreadGc:
        try:
          body
        except Exception, CatchableError:
          let msg =
            "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg()
          for listener in listeners:
            listener.callback(
              RET_ERR,
              cast[ptr cchar](unsafeAddr msg[0]),
              cast[csize_t](len(msg)),
              listener.userData,
            )

template dispatchFFIEvent*(eventName: string, body: untyped) =
  ## Dispatches an FFI event to every listener for `eventName` plus every
  ## wildcard listener. `body` must yield a `string` or `seq[byte]`.
  ##
  ## Valid only on the FFI thread (where `ffiCurrentEventRegistry` is
  ## set). Holds `reg.lock` for the entire snapshot + invocation so a
  ## concurrent `removeEventListener` from a foreign thread blocks until
  ## dispatch returns — closes the UAF window in #40 / PR #39 review
  ## #4356915554. Handlers must not call addEventListener /
  ## removeEventListener on the same registry (would self-deadlock).
  withFFIEventDispatch(eventName, listeners):
    let event = body
    for listener in listeners:
      listener.callback(
        RET_OK,
        cast[ptr cchar](unsafeAddr event[0]),
        cast[csize_t](len(event)),
        listener.userData,
      )

template dispatchFFIEventCbor*(eventName: string, eventPayload: typed) =
  ## Typed CBOR variant of `dispatchFFIEvent`. Wraps `eventPayload` in an
  ## `EventEnvelope`, CBOR-encodes it into a `c_malloc` buffer once, and
  ## fans the same buffer out to every registered listener.
  ##
  ## NB: the template parameter is intentionally named `eventPayload`
  ## rather than `payload` — Nim's template substitution would otherwise
  ## also replace the `payload:` field name inside `EventEnvelope`.
  withFFIEventDispatch(eventName, listeners):
    var (data, dataLen) = cborEncodeShared(
      EventEnvelope[typeof(eventPayload)](eventType: eventName, payload: eventPayload)
    )
    defer:
      cborFreeShared(data)
    for listener in listeners:
      listener.callback(
        RET_OK, cast[ptr cchar](data), cast[csize_t](dataLen), listener.userData
      )
