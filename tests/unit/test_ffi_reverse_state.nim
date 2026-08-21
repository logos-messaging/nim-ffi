## Unit tests for ffi/ffi_reverse.nim: registry, call-id allocation, reply
## mailbox, and the FFI-thread call/drain helpers. Driven single-threaded — the
## test plays host, event thread and FFI thread — so every path is deterministic.

import std/strutils
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
    let (entry, found) = st.beginReverseDispatch("fetch")
    check found
    check entry.userData == addr marker
    st.endReverseDispatch()
    st.setImpl("fetch", nil, nil) # nil fn unregisters
    check not st.hasImpl("fetch")
    let (_, foundAfter) = st.beginReverseDispatch("fetch")
    check not foundAfter

  test "call ids start at 1 and are monotonic":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)

    check st.allocCallId() == 1'u64
    check st.allocCallId() == 2'u64
    check st.allocCallId() == 3'u64

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
    check seen.len == 2
    check 7'u64 in seen
    check 8'u64 in seen
    check st.mailboxLen() == 0

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

## ── ffiReverseCall + drainReverseReplies, single-threaded ───────────────────
## Threadvars are installed by hand: no FFI context, no worker threads. The
## invocation record is read straight off the event ring where the event thread
## would, and the reply is pushed where the host would.

proc recCallId(qe: QueuedEvent): uint64 =
  ## An ekReverse payload is `callId ++ argsCbor` (native endian).
  copyMem(addr result, qe.data, ReverseCallIdPrefixLen)

proc recArgs(qe: QueuedEvent): seq[byte] =
  let n = qe.dataLen - ReverseCallIdPrefixLen
  result = newSeq[byte](n)
  if n > 0:
    copyMem(addr result[0], addr qe.data[ReverseCallIdPrefixLen], n)

template withReverseHarness(stIdent, qIdent: untyped, body: untyped) =
  var stIdent: FFIReverseState
  var qIdent: EventQueue
  initReverseState(stIdent)
  initEventQueue(qIdent)
  ffiCurrentReverseState = addr stIdent
  ffiCurrentEventQueue = addr qIdent
  defer:
    ffiCurrentReverseState = nil
    ffiCurrentEventQueue = nil
    deinitEventQueue(qIdent)
    deinitReverseState(stIdent)
  body

suite "ffiReverseCall":
  test "fails fast when no implementation is registered":
    withReverseHarness(st, q):
      let res = waitFor ffiReverseCall("nobody", @[], 1000)
      check res.isErr()
      check "no host implementation" in res.error
      check q.eventQueueLen() == 0 # nothing was enqueued

  test "roundtrip: ring record carries kind/callId, reply completes the future":
    withReverseHarness(st, q):
      st.setImpl("echo", nopImpl, nil)
      let args = @[byte 1, 2, 3]
      let callFut = ffiReverseCall("echo", args, 2000)

      # The eager part of the async proc ran to its first await: record enqueued.
      let rec = q.peekEvent()
      check rec.isSome()
      check rec.get().kind == ekReverse
      check recCallId(rec.get()) == 1'u64
      check $rec.get().name == "echo"
      let recArgsBytes = recArgs(rec.get())
      check recArgsBytes == args

      # Host answers inline with the args echoed back.
      check st.pushReply(
        recCallId(rec.get()),
        RET_OK,
        cast[pointer](unsafeAddr recArgsBytes[0]),
        recArgsBytes.len,
      ) == REVERSE_ACCEPTED
      q.commitDequeue()
      drainReverseReplies()

      let res = waitFor callFut
      check res.isOk()
      check res.value == args
      check ffiPendingReverseLen() == 0

  test "error reply surfaces the host's message":
    withReverseHarness(st, q):
      st.setImpl("failing", nopImpl, nil)
      let callFut = ffiReverseCall("failing", @[], 2000)
      let rec = q.peekEvent()
      check rec.isSome()
      let msg = "host says no"
      check st.pushReply(
        recCallId(rec.get()), RET_ERR, cast[pointer](unsafeAddr msg[0]), msg.len
      ) == REVERSE_ACCEPTED
      q.commitDequeue()
      drainReverseReplies()
      let res = waitFor callFut
      check res.isErr()
      check res.error == msg

  test "empty RET_OK reply is a real empty payload":
    withReverseHarness(st, q):
      st.setImpl("void_ret", nopImpl, nil)
      let callFut = ffiReverseCall("void_ret", @[], 2000)
      let rec = q.peekEvent()
      check rec.isSome()
      check st.pushReply(recCallId(rec.get()), RET_OK, nil, 0) == REVERSE_ACCEPTED
      q.commitDequeue()
      drainReverseReplies()
      let res = waitFor callFut
      check res.isOk()
      check res.value.len == 0

  test "timeout fails the call and a late reply is dropped":
    withReverseHarness(st, q):
      st.setImpl("silent", nopImpl, nil)
      let callFut = ffiReverseCall("silent", @[], 50)
      let rec = q.peekEvent()
      check rec.isSome()
      let callId = recCallId(rec.get())
      q.commitDequeue()

      let res = waitFor callFut
      check res.isErr()
      check "timed out" in res.error
      check ffiPendingReverseLen() == 0

      # The late reply parks fine and the next drain drops it silently.
      check st.pushReply(callId, RET_OK, nil, 0) == REVERSE_ACCEPTED
      drainReverseReplies()
      check st.mailboxLen() == 0

  test "a reply with an unknown call id is freed and dropped":
    withReverseHarness(st, q):
      check st.pushReply(0xDEAD'u64, RET_OK, nil, 0) == REVERSE_ACCEPTED
      drainReverseReplies()
      check st.mailboxLen() == 0

  test "failPendingReverse fails every parked call":
    withReverseHarness(st, q):
      st.setImpl("parked", nopImpl, nil)
      let callFut = ffiReverseCall("parked", @[], 5000)
      check ffiPendingReverseLen() == 1
      failPendingReverse("context is recycling")
      check ffiPendingReverseLen() == 0
      let res = waitFor callFut
      check res.isErr()
      check "recycling" in res.error
