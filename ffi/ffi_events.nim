## Event registry and dispatch primitives for FFI library-initiated events.
##
## This module owns two concerns so they can evolve together without dragging
## in the rest of `FFIContext`:
##
## 1. A multi-listener registry. Each event name maps to a `seq` of
##    listeners; a dispatched event reaches exactly the listeners
##    subscribed to its name. Callers subscribe to each event separately.
## 2. The dispatch templates (`dispatchFFIEvent`, `dispatchFFIEventCbor`) used
##    by `{.ffiEvent.}`-generated procs. They snapshot the registry under its
##    lock, then invoke each listener *outside* the lock so re-entrant
##    add/remove from within a handler cannot self-deadlock.
##
## Phase 1 keeps dispatch synchronous on the FFI thread. A later phase will
## route events through a bounded queue to a dedicated event thread; the
## registry API does not change.

{.pragma: callback, cdecl, raises: [], gcsafe.}

import std/[locks, sequtils, tables]
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
  return removed

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
  var snap: seq[FFIEventListener] = @[]
  withLock reg.lock:
    # `getOrDefault` returns an empty seq when the key is absent —
    # avoids the raising `[]` operator path.
    for l in reg.byEvent.getOrDefault(eventName):
      snap.add(l)
  return snap

# ---------------------------------------------------------------------------
# Dispatch templates (used by {.ffiEvent.}-generated procs)
# ---------------------------------------------------------------------------

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
  ## Dispatches an FFI event to every listener subscribed to `eventName`.
  ## `body` must yield a `string` or `seq[byte]`.
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
