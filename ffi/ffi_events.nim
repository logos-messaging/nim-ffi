## Event registry and dispatch primitives for FFI library-initiated events.
##
## This module owns two concerns so they can evolve together without dragging
## in the rest of `FFIContext`:
##
## 1. A multi-listener registry. Each event name maps to a `seq` of listeners;
##    the empty event name `""` is the wildcard channel and receives every
##    dispatched event in addition to its own per-name subscribers.
## 2. The dispatch templates (`dispatchFFIEvent`, `dispatchFFIEventCbor`) used
##    by `{.ffiEvent.}`-generated procs. They snapshot the registry under its
##    lock, then invoke each listener *outside* the lock so re-entrant
##    add/remove from within a handler cannot self-deadlock.
##
## Phase 1 keeps dispatch synchronous on the FFI thread. A later phase will
## route events through a bounded queue to a dedicated event thread; the
## registry API does not change.

{.pragma: callback, cdecl, raises: [], gcsafe.}

import std/[locks, tables]
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
    nextId*: uint64
      ## Monotonic id source. 0 is reserved as "invalid"; ids start at 1.
    byEvent*: Table[string, seq[FFIEventListener]]
    wildcard*: seq[FFIEventListener]

const WildcardEventName* = ""
  ## Empty string registers a wildcard listener that receives every event.

# ---------------------------------------------------------------------------
# Registry lifecycle and mutation
# ---------------------------------------------------------------------------

proc initEventRegistry*(reg: var FFIEventRegistry) =
  reg.lock.initLock()
  reg.nextId = 0'u64
  reg.byEvent = initTable[string, seq[FFIEventListener]]()
  reg.wildcard.setLen(0)

proc deinitEventRegistry*(reg: var FFIEventRegistry) =
  reg.lock.deinitLock()
  reg.byEvent.clear()
  reg.wildcard.setLen(0)

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
  var assigned: uint64 = 0
  if callback.isNil():
    return assigned

  withLock reg.lock:
    reg.nextId += 1
    assigned = reg.nextId
    let listener =
      FFIEventListener(id: assigned, callback: callback, userData: userData)
    if eventName.len == 0:
      reg.wildcard.add(listener)
    else:
      # `mgetOrPut` lets us avoid a `[]` lookup that the effect tracker
      # would otherwise see as raising `KeyError`.
      reg.byEvent.mgetOrPut(eventName, @[]).add(listener)
  return assigned

proc removeEventListener*(reg: var FFIEventRegistry, id: uint64): bool {.raises: [].} =
  ## Removes the listener with `id`. Returns true on success, false if no
  ## listener with that id exists. Safe to call from inside a dispatch:
  ## the in-flight snapshot still delivers exactly once to the listener
  ## being removed.
  var removed = false
  if id == 0'u64:
    return removed

  withLock reg.lock:
    for i in 0 ..< reg.wildcard.len:
      if reg.wildcard[i].id == id:
        reg.wildcard.delete(i)
        removed = true
        break
    if not removed:
      for listeners in reg.byEvent.mvalues:
        var idx = -1
        for i in 0 ..< listeners.len:
          if listeners[i].id == id:
            idx = i
            break
        if idx >= 0:
          listeners.delete(idx)
          removed = true
          break
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
# Dispatch templates (used by {.ffiEvent.}-generated procs)
# ---------------------------------------------------------------------------

var ffiCurrentEventRegistry* {.threadvar.}: ptr FFIEventRegistry
  ## Set by the FFI thread at startup so dispatchFFIEvent / dispatchFFIEventCbor
  ## can find their registry without taking a context pointer per call site.

template dispatchFFIEvent*(eventName: string, body: untyped) =
  ## Dispatches an FFI event to every listener for `eventName` plus every
  ## wildcard listener. `body` may produce a `string` or a `seq[byte]` —
  ## the cast to `ptr cchar` accepts both `ptr char` and `ptr byte`.
  ##
  ## Valid only on the FFI thread (i.e., inside {.ffi.} proc bodies and
  ## their async closures, where `ffiCurrentEventRegistry` is set).
  let regPtr = ffiCurrentEventRegistry
  if regPtr.isNil():
    chronicles.error eventName & " - event registry not set on this thread"
  else:
    let snap = snapshotListeners(regPtr[], eventName)
    if snap.len == 0:
      # Not an error: foreign-side code may legitimately not subscribe to
      # every event the lib emits. Log at debug for diagnostics only.
      chronicles.debug eventName & " - no listener registered"
    else:
      foreignThreadGc:
        try:
          let event = body
          for listener in snap:
            listener.callback(
              RET_OK,
              cast[ptr cchar](unsafeAddr event[0]),
              cast[csize_t](len(event)),
              listener.userData,
            )
        except Exception, CatchableError:
          let msg =
            "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg()
          for listener in snap:
            listener.callback(
              RET_ERR,
              cast[ptr cchar](unsafeAddr msg[0]),
              cast[csize_t](len(msg)),
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
  let regPtr = ffiCurrentEventRegistry
  if regPtr.isNil():
    chronicles.error eventName & " - event registry not set on this thread"
  else:
    let snap = snapshotListeners(regPtr[], eventName)
    if snap.len == 0:
      # Not an error: foreign-side code may legitimately not subscribe to
      # every event the lib emits. Log at debug for diagnostics only.
      chronicles.debug eventName & " - no listener registered"
    else:
      foreignThreadGc:
        try:
          var (data, dataLen) = cborEncodeShared(
            EventEnvelope[typeof(eventPayload)](
              eventType: eventName, payload: eventPayload
            )
          )
          defer:
            cborFreeShared(data)
          for listener in snap:
            listener.callback(
              RET_OK,
              cast[ptr cchar](data),
              cast[csize_t](dataLen),
              listener.userData,
            )
        except Exception, CatchableError:
          # Catching `Exception` also catches Defects (OOM, overflow, ...) so
          # the C caller always gets RET_OK / RET_ERR. Requires `--panics:off`
          # (Nim's default; don't enable `--panics:on` for this lib).
          let msg =
            "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg()
          for listener in snap:
            listener.callback(
              RET_ERR,
              cast[ptr cchar](unsafeAddr msg[0]),
              cast[csize_t](len(msg)),
              listener.userData,
            )
