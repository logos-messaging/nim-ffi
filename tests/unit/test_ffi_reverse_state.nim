## Unit tests for ffi/ffi_reverse.nim on a bare FFIReverseState, with no FFI context.

import std/[atomics, locks, os, strutils]
import unittest2
import results
import ffi

proc nopImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  discard

suite "FFIReverseState registry":
  test "set, has, replace and unregister":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)

    check not st.hasImpl("fetch")
    st.setImpl("fetch", nopImpl, nil)
    check st.hasImpl("fetch")
    var marker = 0
    st.setImpl("fetch", nopImpl, addr marker) # replace keeps the name registered
    check st.hasImpl("fetch")
    let entry = st.beginReverseDispatch("fetch")
    check not entry.isNil()
    check entry[].userData == addr marker
    st.endReverseDispatch(entry)
    st.setImpl("fetch", nil, nil) # nil fn unregisters
    check not st.hasImpl("fetch")
    check st.beginReverseDispatch("fetch").isNil()

  test "call ids start at 1 and are monotonic":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)

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

suite "impl ownership (release callback)":
  test "the release runs once, after the last dispatch of the replaced impl":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)
    var box: ReleaseBox
    check st.setImpl("x", nopImpl, addr box, countRelease)
    let entry = st.beginReverseDispatch("x")
    check st.setImpl("x", nopImpl, nil) # replacing does not wait
    check box.released.load() == 0 # the running dispatch still owns it
    st.endReverseDispatch(entry)
    check box.released.load() == 1

  test "an idle impl is released as soon as it is replaced or unregistered":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)
    var a, b: ReleaseBox
    check st.setImpl("x", nopImpl, addr a, countRelease)
    check st.setImpl("x", nopImpl, addr b, countRelease)
    check a.released.load() == 1
    check st.setImpl("x", nil, nil)
    check b.released.load() == 1
    check st.setImpl("absent", nil, nil) # unregistering an unknown name is a no-op

  test "clearImpls releases idle impls and defers the running ones":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)
    var idle, running: ReleaseBox
    check st.setImpl("idle", nopImpl, addr idle, countRelease)
    check st.setImpl("running", nopImpl, addr running, countRelease)
    let entry = st.beginReverseDispatch("running")
    check st.clearImpls() == 1
    check idle.released.load() == 1
    check running.released.load() == 0
    check not st.hasImpl("running")
    st.endReverseDispatch(entry)
    check running.released.load() == 1

  test "deinit releases every impl still registered":
    var st: FFIReverseState
    initReverseState(st)
    var box: ReleaseBox
    check st.setImpl("x", nopImpl, addr box, countRelease)
    deinitReverseState(st)
    check box.released.load() == 1

  test "a nil release never waits and leaves userData to the host":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)
    check st.setImpl("x", nopImpl, nil)
    let entry = st.beginReverseDispatch("x") # a dispatch still runs "x"
    check st.setImpl("x", nil, nil) # returns at once
    check not st.hasImpl("x")
    st.endReverseDispatch(entry)

  test "a full registry is REVERSE_REGISTRY_FULL and never calls the release":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)
    for i in 0 ..< ReverseMaxImpls:
      check st.setImplStatus("impl" & $i, nopImpl, nil) == REVERSE_ACCEPTED
    var box: ReleaseBox
    check st.setImplStatus("one-too-many", nopImpl, addr box, countRelease) ==
      REVERSE_REGISTRY_FULL
    check box.released.load() == 0
    check not st.hasImpl("one-too-many")
    check st.setImplStatus("impl0", nil, nil) == REVERSE_ACCEPTED # a slot comes free

suite "reply mailbox":
  test "push and take returns every parked reply":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)

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
      deinitReverseState(st)

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
      deinitReverseState(st)
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
