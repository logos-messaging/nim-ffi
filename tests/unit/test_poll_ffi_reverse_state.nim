## The state a poll-mode reverse call lives in, without a context or a host:
## the queue the host polls, the mailbox its answers come back through, and what
## a reset drops.

import std/[atomics, os, strutils, tables]
import chronos, results, unittest2
import ffi/poll_ffi_reverse
from ffi/ffi_reverse import
  ReverseQueueDepth, FFIReverseContext, ffiCurrentReverseContext, initReverseContext

proc newRev(): ptr FFIReverse =
  let rev = cast[ptr FFIReverse](allocShared0(sizeof(FFIReverse)))
  initReverse(rev[])
  return rev

proc queueCall(rev: ptr FFIReverse, seqNum: uint64): ptr ReverseInvocation =
  let inv = rev[].newInvocation(1'u64, @[byte 0xa0], 1000)
  doAssert not inv.isNil()
  doAssert rev[].enqueue(inv, seqNum)
  return inv

suite "poll reverse state":
  test "the host gets calls oldest first, with the order mark of each":
    let rev = newRev()
    let first = queueCall(rev, 7)
    let second = queueCall(rev, 9)
    check rev[].headSeq() == 7'u64
    let got = rev[].popForHost()
    check got == first
    check rev[].headSeq() == 9'u64
    check got[].state.load() == ReverseCallState.Delivered
    release(got)
    release(rev[].popForHost())
    check rev[].headSeq() == 0'u64
    release(first)
    release(second)

  test "a call settled while it waited is not handed out":
    let rev = newRev()
    let inv = queueCall(rev, 1)
    inv[].state.store(ReverseCallState.Settled)
    check rev[].popForHost().isNil()
    release(inv)

  test "the queue refuses a call past its cap":
    let rev = newRev()
    var queued: seq[ptr ReverseInvocation] = @[]
    for i in 0 ..< ReverseQueueDepth:
      queued.add(queueCall(rev, uint64(i + 1)))
    let extra = rev[].newInvocation(1'u64, @[], 1000)
    check not rev[].enqueue(extra, 99)
    release(extra)
    release(extra)
    rev[].dropQueuedCalls()
    for inv in queued:
      release(inv)

  test "an answer comes back through the mailbox once":
    let rev = newRev()
    var body = [byte 1, 2, 3]
    check rev[].pushReply(5'u64, 0.cint, addr body[0], body.len)
    let reply = rev[].takeReplies()
    check not reply.isNil()
    check reply[].callId == 5'u64
    check reply[].dataLen == 3
    check reply[].next.isNil()
    freeReply(reply)
    check rev[].takeReplies().isNil()

  test "a reset drops the queued calls and the unread answers":
    let rev = newRev()
    let inv = queueCall(rev, 1)
    check rev[].pushReply(1'u64, 0.cint, nil, 0)
    rev[].dropQueuedCalls()
    check rev[].headSeq() == 0'u64
    check rev[].takeReplies().isNil()
    check inv[].state.load() == ReverseCallState.Settled
    release(inv)

proc ask(rev: ptr FFIReverse, timeoutMs = 1000): Future[Result[seq[byte], string]] =
  return callHost(
    proc() {.gcsafe, raises: [].} =
      discard,
    rev[],
    1'u64,
    @[byte 0xa0],
    proc(): uint64 {.gcsafe, raises: [].} =
      1'u64,
    timeoutMs,
  )

suite "poll reverse calls on one thread":
  test "an answer in time completes the waiting call":
    let rev = newRev()
    let fut = ask(rev)
    check not fut.finished()
    let inv = rev[].popForHost()
    check not inv.isNil()
    var body = [byte 1, 2, 3]
    check rev[].pushReply(inv[].callId, 0.cint, addr body[0], body.len)
    rev[].drainPollReverseReplies()
    check fut.finished()
    check fut.read().get() == @[byte 1, 2, 3]
    release(inv)

  test "a refusal completes it with the host's text":
    let rev = newRev()
    let fut = ask(rev)
    let inv = rev[].popForHost()
    var text = "no thanks"
    check rev[].pushReply(inv[].callId, 1.cint, addr text[0], text.len)
    rev[].drainPollReverseReplies()
    check fut.read().error == "no thanks"
    release(inv)

  test "a call nobody answers fails when overdue, and a late answer is dropped":
    let rev = newRev()
    let fut = ask(rev, timeoutMs = 1)
    let callId = rev[].qHead[].callId
    sleep(10)
    check rev[].popForHost().isNil() # overdue: not handed to the host
    failOverduePollReverseCalls()
    check fut.read().error.contains("did not answer in time")
    check rev[].pushReply(callId, 0.cint, nil, 0)
    rev[].drainPollReverseReplies()
    check ffiPendingReverse.len == 0
    rev[].dropQueuedCalls()

  test "a full queue refuses the call at once":
    let rev = newRev()
    var waiting: seq[Future[Result[seq[byte], string]]] = @[]
    for i in 0 ..< ReverseQueueDepth:
      waiting.add(ask(rev))
    let refused = ask(rev)
    check refused.read().error.contains("queue full")
    failPendingPollReverseCalls("end of test")
    rev[].dropQueuedCalls()
    for fut in waiting:
      check fut.finished()

  test "teardown fails every call still waiting":
    let rev = newRev()
    let fut = ask(rev)
    failPendingPollReverseCalls("the context is closing")
    check fut.read().error == "the context is closing"
    check ffiPendingReverse.len == 0
    rev[].dropQueuedCalls()

  test "a call made while the context is closing fails at once":
    let rev = newRev()
    var closing: FFIReverseContext
    initReverseContext(closing)
    closing.closing.store(true)
    ffiCurrentReverseContext = addr closing
    let fut = ask(rev)
    ffiCurrentReverseContext = nil
    check fut.read().error.contains("closing")
    check ffiPendingReverse.len == 0
    check rev[].headSeq() == 0'u64
