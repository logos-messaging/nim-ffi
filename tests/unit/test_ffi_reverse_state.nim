## Unit tests for ffi/ffi_reverse.nim: registry, call ids, reply mailbox, the
## invocation queue with its Pending/Running/Cancelled state machine, and the
## FFI-thread call/drain helpers. Driven with hand-installed threadvars and a
## real (small) worker pool on a bare FFIReverseState — no FFI context.

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

type EchoBox = object
  st: ptr FFIReverseState

proc echoImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## Answers inline with the args echoed back, straight into the mailbox.
  let box = cast[ptr EchoBox](userData)
  discard box[].st[].pushReply(callId, RET_OK, argsCbor, int(argsLen))

type CountBox = object
  invoked: Atomic[int]

proc countImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  cast[ptr CountBox](userData)[].invoked.atomicInc()

type GateBox = object
  lock: Lock
  cond: Cond
  entered: int
  release: bool

proc gateImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## Parks the worker until the test releases it: models a blocking host impl.
  let g = cast[ptr GateBox](userData)
  acquire(g[].lock)
  g[].entered.inc()
  broadcast(g[].cond)
  while not g[].release:
    wait(g[].cond, g[].lock)
  release(g[].lock)

proc waitEntered(g: var GateBox, n: int) =
  acquire(g.lock)
  while g.entered < n:
    wait(g.cond, g.lock)
  release(g.lock)

proc open(g: var GateBox) =
  acquire(g.lock)
  g.release = true
  broadcast(g.cond)
  release(g.lock)

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

suite "worker pool lifecycle":
  test "start is lazy, idempotent and explicit stop joins every worker":
    var st: FFIReverseState
    initReverseState(st)
    defer:
      deinitReverseState(st)

    check not st.workersStarted()
    check st.startReverseWorkers(3)
    check st.workersStarted()
    check st.workerCount == 3
    check st.startReverseWorkers(7) # already running: keeps its size
    check st.workerCount == 3
    let (stopped, leaked) = stopReverseWorkers(st)
    check stopped == 3
    check leaked == 0
    check not st.workersStarted()
    # Restart after a clean stop works.
    check st.startReverseWorkers(1)
    check st.workerCount == 1

  test "a worker blocked in a host impl is leaked at stop, not joined":
    var st: FFIReverseState
    initReverseState(st)
    var g: GateBox
    g.lock.initLock()
    g.cond.initCond()
    # Size the pool first: `setImpl` starts the default count otherwise, and
    # this test needs exactly one worker so the blocked one is the only one.
    check st.startReverseWorkers(1)
    st.setImpl("gate", gateImpl, addr g)
    ffiCurrentReverseState = addr st
    defer:
      ffiCurrentReverseState = nil

    let callFut = ffiReverseCall("gate", @[], 60_000)
    g.waitEntered(1)
    let (stopped, leaked) = stopReverseWorkers(st)
    check stopped == 0
    check leaked == 1
    check st.leakedWorkers == 1
    # Release the worker so the process can exit; the state stays leaked on
    # purpose (deinit skips the locks a live thread may still touch).
    g.open()
    failPendingReverse("stopped")
    check (waitFor callFut).isErr()
    os.sleep(20)

## ── ffiReverseCall + drainReverseReplies against a real worker pool ─────────

template withReverseHarness(stIdent: untyped, workers: int, body: untyped) =
  var stIdent: FFIReverseState
  initReverseState(stIdent)
  ffiCurrentReverseState = addr stIdent
  if workers > 0:
    check stIdent.startReverseWorkers(workers)
  defer:
    ffiCurrentReverseState = nil
    deinitReverseState(stIdent)
  body

suite "ffiReverseCall":
  test "fails fast when no implementation is registered":
    withReverseHarness(st, 0):
      let res = waitFor ffiReverseCall("nobody", @[], 1000)
      check res.isErr()
      check "no host implementation" in res.error
      check st.queueLen() == 0
      check not st.workersStarted() # nothing was queued, so nothing started

  test "roundtrip: worker runs the impl, reply completes the future":
    withReverseHarness(st, 1):
      var box = EchoBox(st: addr st)
      st.setImpl("echo", echoImpl, addr box)
      let args = @[byte 1, 2, 3]
      var res = Result[seq[byte], string].err("not yet")
      # The reply lands in the mailbox from the worker; poll the drain the way
      # the FFI loop does.
      let callFut = ffiReverseCall("echo", args, 2000)
      while not callFut.finished():
        drainReverseReplies()
        waitFor sleepAsync(chronos.milliseconds(1))
      res = waitFor callFut
      check res.isOk()
      check res.value == args
      check ffiPendingReverseLen() == 0
      check st.queueLen() == 0

  test "workers not started yet are started by the first call":
    withReverseHarness(st, 0):
      var box = EchoBox(st: addr st)
      st.setImpl("echo", echoImpl, addr box)
      let callFut = ffiReverseCall("echo", @[byte 9], 2000)
      check st.workersStarted()
      while not callFut.finished():
        drainReverseReplies()
        waitFor sleepAsync(chronos.milliseconds(1))
      check (waitFor callFut).isOk()

  test "timeout fails the call and a late reply is dropped":
    withReverseHarness(st, 1):
      var g: GateBox
      g.lock.initLock()
      g.cond.initCond()
      st.setImpl("gate", gateImpl, addr g)
      let callFut = ffiReverseCall("gate", @[], 50)
      g.waitEntered(1) # the impl is Running when the deadline fires
      let res = waitFor callFut
      check res.isErr()
      check "timed out" in res.error
      check ffiPendingReverseLen() == 0
      g.open()
      os.sleep(20)
      # A reply for the abandoned call parks fine and the next drain drops it.
      check st.pushReply(1'u64, RET_OK, nil, 0) == REVERSE_ACCEPTED
      drainReverseReplies()
      check st.mailboxLen() == 0

  test "queued calls behind a blocked worker are skipped once expired":
    ## One worker, blocked. Two more calls queue behind it with short deadlines:
    ## they time out on the FFI thread and, when the worker is released, are
    ## dropped at dequeue without ever invoking the impl.
    withReverseHarness(st, 1):
      var g: GateBox
      g.lock.initLock()
      g.cond.initCond()
      var counted: CountBox
      st.setImpl("gate", gateImpl, addr g)
      st.setImpl("count", countImpl, addr counted)

      let blocker = ffiReverseCall("gate", @[], 60_000)
      g.waitEntered(1)
      let a = ffiReverseCall("count", @[], 30)
      let b = ffiReverseCall("count", @[], 30)
      check st.queueLen() == 2
      check (waitFor a).isErr()
      check (waitFor b).isErr()
      check st.queueLen() == 2 # still queued, now Cancelled
      g.open()
      for _ in 0 ..< 200:
        if st.queueLen() == 0:
          break
        os.sleep(1)
      check st.queueLen() == 0
      check counted.invoked.load() == 0 # skipped, never run
      failPendingReverse("done")
      check (waitFor blocker).isErr()

  test "explicit cancel skips a queued call":
    withReverseHarness(st, 1):
      var g: GateBox
      g.lock.initLock()
      g.cond.initCond()
      var counted: CountBox
      st.setImpl("gate", gateImpl, addr g)
      st.setImpl("count", countImpl, addr counted)

      let blocker = ffiReverseCall("gate", @[], 60_000)
      g.waitEntered(1)
      let victim = ffiReverseCall("count", @[], 60_000)
      check st.queueLen() == 1
      waitFor victim.cancelAndWait()
      check victim.cancelled()
      check ffiPendingReverseLen() == 1 # only the blocker remains parked
      g.open()
      for _ in 0 ..< 200:
        if st.queueLen() == 0:
          break
        os.sleep(1)
      check counted.invoked.load() == 0
      failPendingReverse("done")
      check (waitFor blocker).isErr()

  test "two workers run two blocking impls concurrently":
    withReverseHarness(st, 2):
      var g: GateBox
      g.lock.initLock()
      g.cond.initCond()
      st.setImpl("gate", gateImpl, addr g)
      let a = ffiReverseCall("gate", @[], 60_000)
      let b = ffiReverseCall("gate", @[], 60_000)
      g.waitEntered(2) # both impls are inside at the same time
      check st.inFlight() == 2
      g.open()
      failPendingReverse("done")
      check (waitFor a).isErr()
      check (waitFor b).isErr()

  test "scanReverseWorkers reports a stalled worker once and its recovery":
    withReverseHarness(st, 1):
      var g: GateBox
      g.lock.initLock()
      g.cond.initCond()
      st.setImpl("gate", gateImpl, addr g)
      let blocker = ffiReverseCall("gate", @[], 60_000)
      g.waitEntered(1)
      os.sleep(5)
      var hits = st.scanReverseWorkers(1_000_000'i64) # 1 ms stall threshold
      check hits.len == 1
      check hits[0].blocked
      check hits[0].idx == 0
      check hits[0].callId != 0'u64
      check st.scanReverseWorkers(1_000_000'i64).len == 0 # latched
      g.open()
      for _ in 0 ..< 200:
        if st.inFlight() == 0:
          break
        os.sleep(1)
      hits = st.scanReverseWorkers(1_000_000'i64)
      check hits.len == 1
      check not hits[0].blocked
      failPendingReverse("done")
      check (waitFor blocker).isErr()

  test "failPendingReverse fails every parked call and cancels queued ones":
    withReverseHarness(st, 0):
      st.setImpl("parked", nopImpl, nil)
      let callFut = ffiReverseCall("parked", @[], 5000)
      check ffiPendingReverseLen() == 1
      failPendingReverse("context is recycling")
      check ffiPendingReverseLen() == 0
      let res = waitFor callFut
      check res.isErr()
      check "recycling" in res.error
