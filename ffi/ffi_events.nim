## Multi-listener registry primitive for FFI library-initiated events.
##
## Each event name maps to a `seq` of listeners; the empty event name `""`
## is the wildcard channel and receives every dispatched event in addition
## to its own per-name subscribers.
##
## This module ships the data structure only. Dispatch templates that
## consume the registry, plus the FFIContext wiring that exposes the
## registry to {.ffi.}-generated code, land in follow-up PRs. The
## registry is thread-safe via an embedded `Lock`; the future dispatch
## path acquires the lock only long enough to copy out the listener
## slice for the event being dispatched, so re-entrant add/remove from
## within a handler is deadlock-free by construction.

import std/[locks, tables]
import ./ffi_types

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
