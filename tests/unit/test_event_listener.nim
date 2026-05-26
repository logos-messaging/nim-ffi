## Phase 1 unit tests for `FFIEventRegistry` — the multi-listener primitive
## that backs `<lib>_add_event_listener` / `<lib>_remove_event_listener`.
##
## These tests exercise the registry directly (no FFI thread) so they stay
## fast and isolate the registry semantics from the dispatch wiring. The
## existing `test_event_dispatch.nim` covers the end-to-end FFI-thread path.

import std/[atomics, locks]
import unittest2
import ffi

# ---------------------------------------------------------------------------
# Tiny helpers — a thread-safe sink each listener writes into so we can
# assert which callbacks fired and in what order.
# ---------------------------------------------------------------------------

type Recorder = object
  lock: Lock
  hits: seq[string] # tag captured from `userData` per invocation
  retCodes: seq[cint]
  payloads: seq[string]

proc initRecorder(r: var Recorder) =
  r.lock.initLock()

proc deinitRecorder(r: var Recorder) =
  r.lock.deinitLock()

proc record(r: var Recorder, tag: string, retCode: cint, payload: string) =
  acquire(r.lock)
  r.hits.add(tag)
  r.retCodes.add(retCode)
  r.payloads.add(payload)
  release(r.lock)

# Each listener is identified by a `Tag` passed through `userData`.
type Tag = object
  name: string
  rec: ptr Recorder

proc tagCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let t = cast[ptr Tag](userData)
  var payload = newString(int(len))
  if len > 0 and not msg.isNil:
    copyMem(addr payload[0], msg, int(len))
  record(t[].rec[], t[].name, retCode, payload)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "FFIEventRegistry mutation":
  test "addEventListener assigns monotonically increasing non-zero ids":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var t = Tag(name: "a", rec: addr rec)

    let id1 = addEventListener(reg, "evt", tagCb, addr t)
    let id2 = addEventListener(reg, "evt", tagCb, addr t)
    let id3 = addEventListener(reg, "", tagCb, addr t)
    check id1 == 1'u64
    check id2 == 2'u64
    check id3 == 3'u64

  test "addEventListener returns 0 when callback is nil":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    let id = addEventListener(reg, "evt", nil, nil)
    check id == 0'u64

  test "removeEventListener returns false for unknown ids":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    check not removeEventListener(reg, 0'u64)
    check not removeEventListener(reg, 99'u64)

  test "removeEventListener removes from per-event seq and wildcard":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var t = Tag(name: "a", rec: addr rec)

    let id1 = addEventListener(reg, "evt", tagCb, addr t)
    let id2 = addEventListener(reg, "", tagCb, addr t)

    check removeEventListener(reg, id1)
    check removeEventListener(reg, id2)
    # Second remove of the same id is a no-op.
    check not removeEventListener(reg, id1)

    let snap = snapshotListeners(reg, "evt")
    check snap.len == 0

suite "FFIEventRegistry snapshot semantics":
  test "snapshot includes both per-event listeners and wildcards":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var a = Tag(name: "a", rec: addr rec)
    var b = Tag(name: "b", rec: addr rec)
    var c = Tag(name: "c", rec: addr rec)

    discard addEventListener(reg, "evt", tagCb, addr a)
    discard addEventListener(reg, "other", tagCb, addr b)
    discard addEventListener(reg, "", tagCb, addr c)

    let snapEvt = snapshotListeners(reg, "evt")
    check snapEvt.len == 2 # listener for "evt" + wildcard

    let snapOther = snapshotListeners(reg, "other")
    check snapOther.len == 2 # listener for "other" + wildcard

    let snapUnknown = snapshotListeners(reg, "no-subscriber")
    check snapUnknown.len == 1 # only the wildcard

  test "snapshot is a copy: post-snapshot mutation does not affect it":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var t = Tag(name: "a", rec: addr rec)

    let id1 = addEventListener(reg, "evt", tagCb, addr t)
    let snap = snapshotListeners(reg, "evt")
    check snap.len == 1

    # Mutating the registry after the snapshot must not retroactively
    # shrink or grow the snapshot we already captured.
    check removeEventListener(reg, id1)
    discard addEventListener(reg, "evt", tagCb, addr t)
    check snap.len == 1
    check snap[0].id == id1

# ---------------------------------------------------------------------------
# Dispatch-level tests (template-driven, single-thread).
# ---------------------------------------------------------------------------

# Per-thread registry pointer so the dispatch templates find a registry.
# In production this threadvar is set by `ffiThreadBody`; here we set it
# manually because we're not going through the FFI thread.
template withRegistry(reg: var FFIEventRegistry, body: untyped) =
  ffiCurrentEventRegistry = addr reg
  try:
    body
  finally:
    ffiCurrentEventRegistry = nil

type CountedPayload {.ffi.} = object
  value*: int

# A re-entrancy harness: each listener can install/remove other listeners
# while it is being dispatched.
type ReentrantState = object
  rec: ptr Recorder
  reg: ptr FFIEventRegistry
  newListenerId: uint64
  targetId: uint64

proc addedInsideDispatchCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## The "freshly added" listener installed mid-dispatch by
  ## `addInsideDispatchCb`. Just records that it ran.
  let r = cast[ptr Recorder](userData)
  record(r[], "added", retCode, "")

proc addInsideDispatchCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let st = cast[ptr ReentrantState](userData)
  record(st[].rec[], "outer", retCode, "")
  # Install a brand new listener while we're mid-dispatch. The current
  # snapshot must not pick it up — it should only fire on the *next*
  # dispatch.
  st[].newListenerId =
    addEventListener(st[].reg[], "evt", addedInsideDispatchCb, st[].rec)

proc removeInsideDispatchCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let st = cast[ptr ReentrantState](userData)
  record(st[].rec[], "self-remove", retCode, "")
  discard removeEventListener(st[].reg[], st[].targetId)

suite "dispatch via FFIEventRegistry":
  test "multiple listeners on one event all fire":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var a = Tag(name: "a", rec: addr rec)
    var b = Tag(name: "b", rec: addr rec)

    discard addEventListener(reg, "evt", tagCb, addr a)
    discard addEventListener(reg, "evt", tagCb, addr b)

    withRegistry(reg):
      dispatchFFIEventCbor("evt", CountedPayload(value: 42))

    check rec.hits.len == 2
    check ("a" in rec.hits) and ("b" in rec.hits)

  test "listeners on different event names stay isolated":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var a = Tag(name: "a", rec: addr rec)
    var b = Tag(name: "b", rec: addr rec)

    discard addEventListener(reg, "evt-a", tagCb, addr a)
    discard addEventListener(reg, "evt-b", tagCb, addr b)

    withRegistry(reg):
      dispatchFFIEventCbor("evt-a", CountedPayload(value: 1))

    check rec.hits == @["a"]

  test "wildcard receives every event":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var w = Tag(name: "wild", rec: addr rec)
    var s = Tag(name: "specific", rec: addr rec)

    discard addEventListener(reg, "", tagCb, addr w)
    discard addEventListener(reg, "evt", tagCb, addr s)

    withRegistry(reg):
      dispatchFFIEventCbor("evt", CountedPayload(value: 1))
      dispatchFFIEventCbor("other", CountedPayload(value: 2))

    # evt → both specific + wildcard; other → only wildcard.
    check rec.hits.len == 3
    var wildCount = 0
    var specificCount = 0
    for h in rec.hits:
      if h == "wild":
        inc wildCount
      elif h == "specific":
        inc specificCount
    check wildCount == 2
    check specificCount == 1

  test "addEventListener from inside a handler does not deadlock or fire on current event":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var st =
      ReentrantState(rec: addr rec, reg: addr reg, newListenerId: 0, targetId: 0)

    discard addEventListener(reg, "evt", addInsideDispatchCb, addr st)

    withRegistry(reg):
      dispatchFFIEventCbor("evt", CountedPayload(value: 1))

    # Only the original listener fired on this dispatch; the freshly-added
    # listener does not appear in the in-flight snapshot.
    check rec.hits == @["outer"]
    check st.newListenerId != 0

    # The next dispatch picks up both listeners (snapshot is rebuilt):
    # the original "outer" handler runs again *and* the listener it
    # installed during the previous dispatch now fires too.
    withRegistry(reg):
      dispatchFFIEventCbor("evt", CountedPayload(value: 2))
    check rec.hits.len == 3
    check "added" in rec.hits

  test "removeEventListener from inside a handler does not deadlock; in-flight snapshot still fires":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var other = Tag(name: "other", rec: addr rec)
    var st =
      ReentrantState(rec: addr rec, reg: addr reg, newListenerId: 0, targetId: 0)

    let removerId =
      addEventListener(reg, "evt", removeInsideDispatchCb, addr st)
    let otherId = addEventListener(reg, "evt", tagCb, addr other)
    st.targetId = otherId

    withRegistry(reg):
      dispatchFFIEventCbor("evt", CountedPayload(value: 1))

    # The in-flight snapshot captured `other` before the remover ran, so
    # `other` still fires exactly once on this dispatch even though it
    # was removed mid-loop.
    check ("self-remove" in rec.hits) and ("other" in rec.hits)
    check rec.hits.len == 2

    # On the next dispatch, the removed listener is gone.
    let beforeLen = rec.hits.len
    withRegistry(reg):
      dispatchFFIEventCbor("evt", CountedPayload(value: 2))
    check rec.hits.len == beforeLen + 1
    check rec.hits[^1] == "self-remove"

    # Suppress the unused-binding warning under DCE-stripped builds.
    discard removerId

suite "removeAllEventListeners":
  test "drops every listener (per-event and wildcard)":
    var reg: FFIEventRegistry
    initEventRegistry(reg)
    defer:
      deinitEventRegistry(reg)
    var rec: Recorder
    initRecorder(rec)
    defer:
      deinitRecorder(rec)
    var a = Tag(name: "a", rec: addr rec)
    var b = Tag(name: "b", rec: addr rec)

    discard addEventListener(reg, "evt", tagCb, addr a)
    discard addEventListener(reg, WildcardEventName, tagCb, addr b)
    removeAllEventListeners(reg)

    check snapshotListeners(reg, "evt").len == 0
    check snapshotListeners(reg, WildcardEventName).len == 0
