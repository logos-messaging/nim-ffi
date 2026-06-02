## Unit tests for the `FFIEventRegistry` primitive — the multi-listener
## data structure that will back `<lib>_add_event_listener` /
## `<lib>_remove_event_listener` once the dispatch wiring lands.
##
## These tests exercise the registry directly (no FFI thread, no dispatch
## templates) so they stay fast and pin down the registry's mutation and
## snapshot semantics in isolation.

import std/locks
import unittest2
import ffi

# ---------------------------------------------------------------------------
# Tiny helpers — a thread-safe sink each listener writes into so we can
# assert which callbacks would fire and in what order once dispatch lands.
# Today only `tagCb`'s presence is exercised; the recorder is also used to
# make sure listener bookkeeping doesn't accidentally invoke callbacks.
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
    let id3 = addEventListener(reg, "other", tagCb, addr t)
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

  test "removeEventListener removes listeners across distinct events":
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
    let id2 = addEventListener(reg, "other", tagCb, addr t)

    check removeEventListener(reg, id1)
    check removeEventListener(reg, id2)
    # Second remove of the same id is a no-op.
    check not removeEventListener(reg, id1)

    check snapshotListeners(reg, "evt").len == 0
    check snapshotListeners(reg, "other").len == 0

suite "FFIEventRegistry snapshot semantics":
  test "snapshot returns only the listeners for the requested event":
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
    discard addEventListener(reg, "evt", tagCb, addr b)
    discard addEventListener(reg, "other", tagCb, addr c)

    let snapEvt = snapshotListeners(reg, "evt")
    check snapEvt.len == 2 # both listeners for "evt"

    let snapOther = snapshotListeners(reg, "other")
    check snapOther.len == 1 # only the listener for "other"

    let snapUnknown = snapshotListeners(reg, "no-subscriber")
    check snapUnknown.len == 0 # no listener for this event

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

suite "removeAllEventListeners":
  test "drops every registered listener":
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
    discard addEventListener(reg, "other", tagCb, addr b)
    removeAllEventListeners(reg)

    check snapshotListeners(reg, "evt").len == 0
    check snapshotListeners(reg, "other").len == 0
