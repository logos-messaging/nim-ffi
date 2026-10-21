## Unit tests for the `FFIEventRegistry` primitive (no FFI thread).

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

type SiblingRemover = object
  reg: ptr FFIEventRegistry
  rec: ptr Recorder
  victimId: uint64
  victimData: ptr int
  removed: bool

type MassRemover = object
  reg: ptr FFIEventRegistry
  rec: ptr Recorder
  useClear: bool

type ReAdder = object
  reg: ptr FFIEventRegistry
  rec: ptr Recorder
  victimId: uint64
  victim: ptr Tag
  readdedId: uint64
  done: bool

var gVictimCalled: bool

proc removeSiblingCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Removes the victim and frees its user data, as a generated C++ remove does.
  let r = cast[ptr SiblingRemover](userData)
  record(r[].rec[], "remover", retCode, "")
  r[].removed = removeEventListener(r[].reg[], r[].victimId)
  freeShared(r[].victimData)

proc victimCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  gVictimCalled = cast[ptr int](userData)[] == 1

proc removeAllCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let m = cast[ptr MassRemover](userData)
  record(m[].rec[], "remover", retCode, "")
  if m[].useClear:
    clearListeners(m[].reg[])
  else:
    removeAllEventListeners(m[].reg[])

proc reAddCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let r = cast[ptr ReAdder](userData)
  record(r[].rec[], "readder", retCode, "")
  if not r[].done:
    r[].done = true
    if removeEventListener(r[].reg[], r[].victimId):
      r[].readdedId = addEventListener(r[].reg[], "evt", tagCb, r[].victim)

proc dispatch(reg: var FFIEventRegistry, eventName: string, errMsg = "") =
  let listeners = reg.beginDispatch(eventName)
  defer:
    reg.endDispatch()
  if errMsg.len > 0:
    reg.notifyListenersErr(eventName, listeners, errMsg)
    return
  reg.notifyListeners(eventName, listeners, RET_OK, nil, 0)

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

  test "a listener removed by a sibling during the dispatch is not called":
    for (errMsg, retCode) in [("", RET_OK), ("boom", RET_ERR)]:
      setupRegistry(reg)
      setupRecorder(rec)
      var remover = SiblingRemover(reg: addr reg, rec: addr rec)
      var tail = Tag(name: "tail", rec: addr rec)
      let victimData = createShared(int)
      victimData[] = 1
      gVictimCalled = false

      check addEventListener(reg, "evt", removeSiblingCb, addr remover) > 0
      remover.victimId = addEventListener(reg, "evt", victimCb, victimData)
      remover.victimData = victimData
      check remover.victimId > 0
      check addEventListener(reg, "evt", tagCb, addr tail) > 0

      reg.dispatch("evt", errMsg)

      check remover.removed
      check not gVictimCalled
      check rec.hits == @["remover", "tail"]
      check rec.retCodes == @[retCode, retCode]
      check rec.payloads == @["", errMsg]

  test "a callback that drops every listener mid-dispatch skips the rest":
    for useClear in [false, true]:
      setupRegistry(reg)
      setupRecorder(rec)
      var mass = MassRemover(reg: addr reg, rec: addr rec, useClear: useClear)
      var tail = Tag(name: "tail", rec: addr rec)

      check addEventListener(reg, "evt", removeAllCb, addr mass) > 0
      check addEventListener(reg, "evt", tagCb, addr tail) > 0
      check addEventListener(reg, "other", tagCb, addr tail) > 0

      reg.dispatch("evt")

      check rec.hits == @["remover"]
      check snapshotListeners(reg, "evt").len == 0
      check snapshotListeners(reg, "other").len == 0

  test "a listener removed and re-added mid-dispatch is not called with its old entry":
    setupRegistry(reg)
    setupRecorder(rec)
    var victim = Tag(name: "victim", rec: addr rec)
    var tail = Tag(name: "tail", rec: addr rec)
    var readder = ReAdder(reg: addr reg, rec: addr rec, victim: addr victim)

    check addEventListener(reg, "evt", reAddCb, addr readder) > 0
    readder.victimId = addEventListener(reg, "evt", tagCb, addr victim)
    check readder.victimId > 0
    check addEventListener(reg, "evt", tagCb, addr tail) > 0

    reg.dispatch("evt")

    check readder.readdedId > readder.victimId
    check rec.hits == @["readder", "tail"]

    reg.dispatch("evt")

    check rec.hits == @["readder", "tail", "readder", "tail", "victim"]

  test "removing a listener of another event does not skip the dispatched ones":
    setupRegistry(reg)
    setupRecorder(rec)
    var remover = SiblingRemover(reg: addr reg, rec: addr rec)
    var tail = Tag(name: "tail", rec: addr rec)
    let otherData = createShared(int)
    otherData[] = 1

    check addEventListener(reg, "evt", removeSiblingCb, addr remover) > 0
    check addEventListener(reg, "evt", tagCb, addr tail) > 0
    remover.victimId = addEventListener(reg, "other", victimCb, otherData)
    remover.victimData = otherData
    check remover.victimId > 0

    reg.dispatch("evt")

    check remover.removed
    check rec.hits == @["remover", "tail"]
    check snapshotListeners(reg, "evt").len == 2
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
