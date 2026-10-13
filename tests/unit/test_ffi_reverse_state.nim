## Unit tests for ffi/ffi_reverse.nim on a bare FFIReverseState, with no FFI context.

import std/[atomics, locks, os, strutils]
import unittest2
import results
import ffi

proc nopImpl(
    callId: uint64, args: ptr UncheckedArray[byte], argsLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

suite "FFIReverseState registry":
  test "set, has, replace and unregister":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()

    check not st.isRegistered("fetch")
    check st.registerImpl("fetch", nopImpl, nil).isOk()
    check st.isRegistered("fetch")
    var marker = 0
    check st.registerImpl("fetch", nopImpl, addr marker).isOk()
      # replace keeps the name registered
    check st.isRegistered("fetch")
    # begin/end stand in for a reverse worker; the host never calls them.
    let entry = st.beginReverseDispatch("fetch")
    require not entry.isNil()
    check entry[].userData == addr marker
    st.endReverseDispatch(entry)
    st.unregisterImpl("fetch")
    check not st.isRegistered("fetch")
    check st.beginReverseDispatch("fetch").isNil()

  test "call ids start at 1 and are monotonic":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()

    check st.allocCallId() == 1'u64
    check st.allocCallId() == 2'u64
    check st.allocCallId() == 3'u64

type ReleaseBox = object
  st: ptr FFIReverseState
  released: Atomic[int]
  releasedInside: Atomic[int] # -1 until the impl recorded it
  done: Atomic[bool]

proc countRelease(userData: pointer) {.cdecl, gcsafe, raises: [].} =
  cast[ptr ReleaseBox](userData)[].released.atomicInc()

type InFlightProbe = object
  st: ptr FFIReverseState
  seen: Atomic[int]

proc inFlightRelease(userData: pointer) {.cdecl, gcsafe, raises: [].} =
  ## Records how many dispatches count as in flight while the release runs.
  let p = cast[ptr InFlightProbe](userData)
  p[].seen.store(p[].st[].inFlight())

suite "impl ownership (release callback)":
  test "a dispatch still counts as in flight while its release runs":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()
    var probe = InFlightProbe(st: addr st)
    probe.seen.store(-1)
    check st.registerImpl("x", nopImpl, addr probe, inFlightRelease).isOk()
    let entry = st.beginReverseDispatch("x") # stands in for a reverse worker
    require not entry.isNil()
    st.unregisterImpl("x") # the dispatch now holds the last reference
    st.endReverseDispatch(entry) # drops it: the release runs in here
    # A recycle that waits for inFlight() == 0 therefore also waits for the release.
    check probe.seen.load() == 1

  test "the release runs once, after the last dispatch of the replaced impl":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()
    var box: ReleaseBox
    check st.registerImpl("x", nopImpl, addr box, countRelease).isOk()
    let entry = st.beginReverseDispatch("x")
    check st.registerImpl("x", nopImpl, nil).isOk() # replacing does not wait
    check box.released.load() == 0 # the running dispatch still owns it
    st.endReverseDispatch(entry)
    check box.released.load() == 1

  test "an idle impl is released as soon as it is replaced or unregistered":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()
    var a, b: ReleaseBox
    check st.registerImpl("x", nopImpl, addr a, countRelease).isOk()
    check st.registerImpl("x", nopImpl, addr b, countRelease).isOk()
    check a.released.load() == 1
    st.unregisterImpl("x")
    check b.released.load() == 1
    st.unregisterImpl("absent") # unregistering an unknown name is a no-op

  test "clearImpls releases idle impls and defers the running ones":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()
    var idle, running: ReleaseBox
    check st.registerImpl("idle", nopImpl, addr idle, countRelease).isOk()
    check st.registerImpl("running", nopImpl, addr running, countRelease).isOk()
    let entry = st.beginReverseDispatch("running")
    check st.clearImpls() == 1
    check idle.released.load() == 1
    check running.released.load() == 0
    check not st.isRegistered("running")
    st.endReverseDispatch(entry)
    check running.released.load() == 1

  test "deinit releases every impl still registered":
    var st: FFIReverseState
    initReverseState(st)
    var box: ReleaseBox
    check st.registerImpl("x", nopImpl, addr box, countRelease).isOk()
    check deinitReverseState(st).isOk()
    check box.released.load() == 1

  test "deinit keeps the locks alive while an impl still runs":
    var st: FFIReverseState
    initReverseState(st)
    var box: ReleaseBox
    check st.registerImpl("x", nopImpl, addr box, countRelease).isOk()
    let entry = st.beginReverseDispatch("x")
    check deinitReverseState(st).isErr() # the dispatch below still takes the lock
    st.endReverseDispatch(entry)
    check box.released.load() == 1
    check deinitReverseState(st).isOk()

  test "a nil release never waits and leaves userData to the host":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()
    check st.registerImpl("x", nopImpl, nil).isOk()
    let entry = st.beginReverseDispatch("x") # a dispatch still runs "x"
    st.unregisterImpl("x") # returns at once
    check not st.isRegistered("x")
    st.endReverseDispatch(entry)

  test "a full registry is RegistryFull and never calls the release":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()
    for i in 0 ..< ReverseMaxImpls:
      check st.registerImpl("impl" & $i, nopImpl, nil).isOk()
    var box: ReleaseBox
    let full = st.registerImpl("one-too-many", nopImpl, addr box, countRelease)
    check full.isErr() and full.error == ReverseError.RegistryFull
    check box.released.load() == 0
    check not st.isRegistered("one-too-many")
    st.unregisterImpl("impl0") # a slot comes free
    check st.registerImpl("one-too-many", nopImpl, nil).isOk()

suite "reply mailbox":
  test "push and take returns every parked reply":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()

    var payload = [byte 0xAA, 0xBB]
    check st.pushReply(7'u64, RET_OK, addr payload[0], payload.len) == REVERSE_ACCEPTED
    check st.pushReply(8'u64, RET_ERR, nil, 0) == REVERSE_ACCEPTED
    check st.mailboxLen() == 2

    var seen: seq[uint64] = @[]
    var node = st.takeReplies()
    while not node.isNil():
      let next = node[].next
      seen.add(node[].callId)
      if node[].callId == 7'u64:
        check node[].retCode == RET_OK
        check node[].dataLen == 2
        check node[].data[0] == 0xAA'u8
        check node[].data[1] == 0xBB'u8
      freeReply(node)
      node = next
    check seen == @[7'u64, 8'u64] # FIFO: the first reply for a call id wins
    check st.mailboxLen() == 0

    # The tail resets with the take, so the next push starts a fresh list.
    check st.pushReply(9'u64, RET_OK, nil, 0) == REVERSE_ACCEPTED
    let single = st.takeReplies()
    check single[].callId == 9'u64
    check single[].next.isNil()
    freeReply(single)

  test "mailbox rejects pushes past ReverseMailboxDepth":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()

    for i in 0 ..< ReverseMailboxDepth:
      check st.pushReply(uint64(i + 1), RET_OK, nil, 0) == REVERSE_ACCEPTED
    check st.pushReply(uint64(ReverseMailboxDepth + 1), RET_OK, nil, 0) ==
      REVERSE_MAILBOX_FULL
    st.freeAllReplies()
    check st.mailboxLen() == 0

  test "the wake hook fires once per empty-to-non-empty transition":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      check deinitReverseState(st).isOk()
    var wakes = 0
    proc countWake(ud: pointer) {.nimcall, gcsafe, raises: [].} =
      cast[ptr int](ud)[].inc()

    st.installContextHooks(countWake, nil, addr wakes)

    check st.pushReply(1'u64, RET_OK, nil, 0) == REVERSE_ACCEPTED
    check st.pushReply(2'u64, RET_OK, nil, 0) == REVERSE_ACCEPTED
    check st.pushReply(3'u64, RET_OK, nil, 0) == REVERSE_ACCEPTED
    check wakes == 1
    st.freeAllReplies()
    check st.pushReply(4'u64, RET_OK, nil, 0) == REVERSE_ACCEPTED
    check wakes == 2
    st.freeAllReplies()
