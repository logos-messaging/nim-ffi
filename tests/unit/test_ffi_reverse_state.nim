## Unit tests for ffi/ffi_reverse.nim on a bare FFIReverseContext, with no FFI context.

import std/[atomics, locks, os, strutils]
import unittest2
import results
import ffi

proc nopImpl(
    ctx: pointer,
    callId: uint64,
    args: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  discard

# Impl ids, as the {.ffiReverse.} macro would assign them.
const
  Fetch = 0
  X = 0
  Idle = 0
  Running = 1
  Absent = 7

suite "FFIReverseContext registry":
  test "set, has, replace and unregister":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()

    check not st.isRegistered(Fetch)
    check st.registerImpl(Fetch, nopImpl, nil).isOk()
    check st.isRegistered(Fetch)
    var marker = 0
    check st.registerImpl(Fetch, nopImpl, addr marker).isOk()
      # replace keeps the name registered
    check st.isRegistered(Fetch)
    # begin/end stand in for a reverse worker; the host never calls them.
    let entry = st.beginReverseDispatch(Fetch)
    require not entry.isNil()
    check entry[].userData == addr marker
    st.endReverseDispatch(entry)
    st.unregisterImpl(Fetch)
    check not st.isRegistered(Fetch)
    check st.beginReverseDispatch(Fetch).isNil()

  test "call ids start at 1 and are monotonic":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()

    check st.allocCallId() == 1'u64
    check st.allocCallId() == 2'u64
    check st.allocCallId() == 3'u64

type ReleaseBox = object
  st: ptr FFIReverseContext
  released: Atomic[int]
  releasedInside: Atomic[int] # -1 until the impl recorded it
  done: Atomic[bool]

proc countRelease(userData: pointer) {.cdecl, gcsafe, raises: [].} =
  cast[ptr ReleaseBox](userData)[].released.atomicInc()

type InFlightProbe = object
  st: ptr FFIReverseContext
  seen: Atomic[int]

proc inFlightRelease(userData: pointer) {.cdecl, gcsafe, raises: [].} =
  ## Records how many dispatches count as in flight while the release runs.
  let p = cast[ptr InFlightProbe](userData)
  p[].seen.store(p[].st[].inFlight())

suite "impl ownership (release callback)":
  test "a dispatch still counts as in flight while its release runs":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    var probe = InFlightProbe(st: addr st)
    probe.seen.store(-1)
    check st.registerImpl(X, nopImpl, addr probe, inFlightRelease).isOk()
    let entry = st.beginReverseDispatch(X) # stands in for a reverse worker
    require not entry.isNil()
    st.unregisterImpl(X) # the dispatch now holds the last reference
    st.endReverseDispatch(entry) # drops it: the release runs in here
    # A recycle that waits for inFlight() == 0 therefore also waits for the release.
    check probe.seen.load() == 1

  test "the release runs once, after the last dispatch of the replaced impl":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    var box: ReleaseBox
    check st.registerImpl(X, nopImpl, addr box, countRelease).isOk()
    let entry = st.beginReverseDispatch(X)
    check st.registerImpl(X, nopImpl, nil).isOk() # replacing does not wait
    check box.released.load() == 0 # the running dispatch still owns it
    st.endReverseDispatch(entry)
    check box.released.load() == 1

  test "an idle impl is released as soon as it is replaced or unregistered":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    var a, b: ReleaseBox
    check st.registerImpl(X, nopImpl, addr a, countRelease).isOk()
    check st.registerImpl(X, nopImpl, addr b, countRelease).isOk()
    check a.released.load() == 1
    st.unregisterImpl(X)
    check b.released.load() == 1
    st.unregisterImpl(Absent) # unregistering an unknown id is a no-op

  test "clearImpls releases idle impls and defers the running ones":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    var idle, running: ReleaseBox
    check st.registerImpl(Idle, nopImpl, addr idle, countRelease).isOk()
    check st.registerImpl(Running, nopImpl, addr running, countRelease).isOk()
    let entry = st.beginReverseDispatch(Running)
    check st.clearImpls() == 1
    check idle.released.load() == 1
    check running.released.load() == 0
    check not st.isRegistered(Running)
    st.endReverseDispatch(entry)
    check running.released.load() == 1

  test "deinit releases every impl still registered":
    var st: FFIReverseContext
    initReverseContext(st)
    var box: ReleaseBox
    check st.registerImpl(X, nopImpl, addr box, countRelease).isOk()
    check deinitReverseContext(st).isOk()
    check box.released.load() == 1

  test "deinit keeps the locks alive while an impl still runs":
    var st: FFIReverseContext
    initReverseContext(st)
    var box: ReleaseBox
    check st.registerImpl(X, nopImpl, addr box, countRelease).isOk()
    let entry = st.beginReverseDispatch(X)
    check deinitReverseContext(st).isErr() # the dispatch below still takes the lock
    st.endReverseDispatch(entry)
    check box.released.load() == 1
    check deinitReverseContext(st).isOk()

  test "a nil release never waits and leaves userData to the host":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    check st.registerImpl(X, nopImpl, nil).isOk()
    let entry = st.beginReverseDispatch(X) # a dispatch still runs X
    st.unregisterImpl(X) # returns at once
    check not st.isRegistered(X)
    st.endReverseDispatch(entry)

  test "the registry grows to any impl id":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    check st.registerImpl(100, nopImpl, nil).isOk()
    check st.isRegistered(100)
    check not st.isRegistered(99)
    check not st.isRegistered(1000) # past the grown size
    check st.registerImpl(3, nopImpl, nil).isOk() # below it: no regrowth needed
    check st.isRegistered(3) and st.isRegistered(100)

suite "reply mailbox":
  test "push and take returns every parked reply":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()

    var payload = [byte 0xAA, 0xBB]
    check st.pushReply(7'u64, RET_OK, addr payload[0], payload.len) == RET_OK
    check st.pushReply(8'u64, RET_ERR, nil, 0) == RET_OK
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
    check st.pushReply(9'u64, RET_OK, nil, 0) == RET_OK
    let single = st.takeReplies()
    check single[].callId == 9'u64
    check single[].next.isNil()
    freeReply(single)

  test "mailbox rejects pushes past ReverseMailboxDepth":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()

    for i in 0 ..< ReverseMailboxDepth:
      check st.pushReply(uint64(i + 1), RET_OK, nil, 0) == RET_OK
    check st.pushReply(uint64(ReverseMailboxDepth + 1), RET_OK, nil, 0) == RET_QUEUE_FULL
    st.freeAllReplies()
    check st.mailboxLen() == 0

  test "the wake hook fires once per empty-to-non-empty transition":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    var wakes = 0
    proc countWake(ud: pointer) {.nimcall, gcsafe, raises: [].} =
      cast[ptr int](ud)[].inc()

    st.installContextHooks(countWake, nil, addr wakes)

    check st.pushReply(1'u64, RET_OK, nil, 0) == RET_OK
    check st.pushReply(2'u64, RET_OK, nil, 0) == RET_OK
    check st.pushReply(3'u64, RET_OK, nil, 0) == RET_OK
    check wakes == 1
    st.freeAllReplies()
    check st.pushReply(4'u64, RET_OK, nil, 0) == RET_OK
    check wakes == 2
    st.freeAllReplies()
