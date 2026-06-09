## Unit tests for the `FFIEventRegistry` primitive (no FFI thread, no dispatch).

import std/locks
import unittest2
import ffi

type Recorder = object
  lock: Lock
  hits: seq[string]
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

template setupRegistry(regIdent: untyped) =
  var regIdent: FFIEventRegistry
  initEventRegistry(regIdent)
  defer:
    deinitEventRegistry(regIdent)

template setupRecorder(recIdent: untyped) =
  var recIdent: Recorder
  initRecorder(recIdent)
  defer:
    deinitRecorder(recIdent)

suite "FFIEventRegistry mutation":
  test "addEventListener assigns monotonically increasing non-zero ids":
    setupRegistry(reg)
    setupRecorder(rec)
    var t = Tag(name: "a", rec: addr rec)

    let id1 = addEventListener(reg, "evt", tagCb, addr t)
    let id2 = addEventListener(reg, "evt", tagCb, addr t)
    let id3 = addEventListener(reg, "other", tagCb, addr t)
    check id1 == 1'u64
    check id2 == 2'u64
    check id3 == 3'u64

  test "addEventListener returns 0 when callback is nil":
    setupRegistry(reg)
    let id = addEventListener(reg, "evt", nil, nil)
    check id == 0'u64

  test "removeEventListener returns false for unknown ids":
    setupRegistry(reg)
    check not removeEventListener(reg, 0'u64)
    check not removeEventListener(reg, 99'u64)

  test "removeEventListener removes listeners across distinct events":
    setupRegistry(reg)
    setupRecorder(rec)
    var t = Tag(name: "a", rec: addr rec)

    let id1 = addEventListener(reg, "evt", tagCb, addr t)
    let id2 = addEventListener(reg, "other", tagCb, addr t)

    check removeEventListener(reg, id1)
    check removeEventListener(reg, id2)
    check not removeEventListener(reg, id1)

    check snapshotListeners(reg, "evt").len == 0
    check snapshotListeners(reg, "other").len == 0

suite "FFIEventRegistry snapshot semantics":
  test "snapshot returns only the listeners for the requested event":
    setupRegistry(reg)
    setupRecorder(rec)
    var a = Tag(name: "a", rec: addr rec)
    var b = Tag(name: "b", rec: addr rec)
    var c = Tag(name: "c", rec: addr rec)

    discard addEventListener(reg, "evt", tagCb, addr a)
    discard addEventListener(reg, "evt", tagCb, addr b)
    discard addEventListener(reg, "other", tagCb, addr c)

    check snapshotListeners(reg, "evt").len == 2
    check snapshotListeners(reg, "other").len == 1
    check snapshotListeners(reg, "no-subscriber").len == 0

  test "snapshot is a copy: post-snapshot mutation does not affect it":
    setupRegistry(reg)
    setupRecorder(rec)
    var t = Tag(name: "a", rec: addr rec)

    let id1 = addEventListener(reg, "evt", tagCb, addr t)
    let snap = snapshotListeners(reg, "evt")
    check snap.len == 1

    check removeEventListener(reg, id1)
    discard addEventListener(reg, "evt", tagCb, addr t)
    check snap.len == 1
    check snap[0].id == id1

suite "removeAllEventListeners":
  test "drops every registered listener":
    setupRegistry(reg)
    setupRecorder(rec)
    var a = Tag(name: "a", rec: addr rec)
    var b = Tag(name: "b", rec: addr rec)

    discard addEventListener(reg, "evt", tagCb, addr a)
    discard addEventListener(reg, "other", tagCb, addr b)
    removeAllEventListeners(reg)

    check snapshotListeners(reg, "evt").len == 0
    check snapshotListeners(reg, "other").len == 0
