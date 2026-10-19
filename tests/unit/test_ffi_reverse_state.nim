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

type EchoBox = object
  st: ptr FFIReverseContext

proc echoImpl(
    callId: uint64, args: ptr UncheckedArray[byte], argsLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Answers inline with the args echoed back, straight into the mailbox.
  let box = cast[ptr EchoBox](userData)
  discard box[].st[].pushReply(callId, RET_OK, args, int(argsLen))

type GateBox = object
  lock: Lock
  cond: Cond
  entered: int
  release: bool

proc gateImpl(
    callId: uint64, args: ptr UncheckedArray[byte], argsLen: csize_t, userData: pointer
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

suite "FFIReverseContext registry":
  test "set, has, replace and unregister":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()

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
    check st.registerImpl("x", nopImpl, addr probe, inFlightRelease).isOk()
    let entry = st.beginReverseDispatch("x") # stands in for a reverse worker
    require not entry.isNil()
    st.unregisterImpl("x") # the dispatch now holds the last reference
    st.endReverseDispatch(entry) # drops it: the release runs in here
    # A recycle that waits for inFlight() == 0 therefore also waits for the release.
    check probe.seen.load() == 1

  test "the release runs once, after the last dispatch of the replaced impl":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    var box: ReleaseBox
    check st.registerImpl("x", nopImpl, addr box, countRelease).isOk()
    let entry = st.beginReverseDispatch("x")
    check st.registerImpl("x", nopImpl, nil).isOk() # replacing does not wait
    check box.released.load() == 0 # the running dispatch still owns it
    st.endReverseDispatch(entry)
    check box.released.load() == 1

  test "an idle impl is released as soon as it is replaced or unregistered":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    var a, b: ReleaseBox
    check st.registerImpl("x", nopImpl, addr a, countRelease).isOk()
    check st.registerImpl("x", nopImpl, addr b, countRelease).isOk()
    check a.released.load() == 1
    st.unregisterImpl("x")
    check b.released.load() == 1
    st.unregisterImpl("absent") # unregistering an unknown name is a no-op

  test "clearImpls releases idle impls and defers the running ones":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
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
    var st: FFIReverseContext
    initReverseContext(st)
    var box: ReleaseBox
    check st.registerImpl("x", nopImpl, addr box, countRelease).isOk()
    check deinitReverseContext(st).isOk()
    check box.released.load() == 1

  test "deinit keeps the locks alive while an impl still runs":
    var st: FFIReverseContext
    initReverseContext(st)
    var box: ReleaseBox
    check st.registerImpl("x", nopImpl, addr box, countRelease).isOk()
    let entry = st.beginReverseDispatch("x")
    check deinitReverseContext(st).isErr() # the dispatch below still takes the lock
    st.endReverseDispatch(entry)
    check box.released.load() == 1
    check deinitReverseContext(st).isOk()

  test "a nil release never waits and leaves userData to the host":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
    check st.registerImpl("x", nopImpl, nil).isOk()
    let entry = st.beginReverseDispatch("x") # a dispatch still runs "x"
    st.unregisterImpl("x") # returns at once
    check not st.isRegistered("x")
    st.endReverseDispatch(entry)

  test "a full registry is RegistryFull and never calls the release":
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()
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
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()

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
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()

    for i in 0 ..< ReverseMailboxDepth:
      check st.pushReply(uint64(i + 1), RET_OK, nil, 0) == REVERSE_ACCEPTED
    check st.pushReply(uint64(ReverseMailboxDepth + 1), RET_OK, nil, 0) ==
      REVERSE_MAILBOX_FULL
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
    var st: FFIReverseContext
    initReverseContext(st)
    defer:
      check deinitReverseContext(st).isOk()

    check not st.workersStarted()
    check st.startReverseWorkers(3)
    check st.workersStarted()
    check st.workerCount == 3
    check st.startReverseWorkers(7) # already running: keeps its size
    check st.workerCount == 3
    let stop = stopReverseWorkers(st)
    check stop.stopped == 3
    check stop.leaked == 0
    check not st.workersStarted()
    check st.startReverseWorkers(1)
    check st.workerCount == 1

  test "a stop right after the start does not strand a worker that has not run yet":
    # The claimed stop clears `workers`; each worker got its own slot at creation.
    for _ in 0 ..< 200:
      var st: FFIReverseContext
      initReverseContext(st)
      check st.startReverseWorkers(2)
      let stop = stopReverseWorkers(st)
      check stop.stopped == 2
      check stop.leaked == 0
      check deinitReverseContext(st).isOk()

template withReverseHarness(stIdent: untyped, workers: int, body: untyped) =
  var stIdent: FFIReverseContext
  initReverseContext(stIdent)
  ffiCurrentReverseContext = addr stIdent
  if workers > 0:
    check stIdent.startReverseWorkers(workers)
  defer:
    ffiCurrentReverseContext = nil
    check deinitReverseContext(stIdent).isOk()
  body

suite "ffiReverseCall":
  test "fails fast once the context is closing, without queueing":
    withReverseHarness(st, 0):
      check st.registerImpl("echo", nopImpl, nil).isOk()
      st.closing.store(true)
      let res = waitFor ffiReverseCall("echo", @[], 1000)
      check res.isErr()
      check "closing" in res.error
      check st.queueLen() == 0
      check ffiPendingReverseLen() == 0

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
      check st.registerImpl("echo", echoImpl, addr box).isOk()
      let args = @[byte 1, 2, 3]
      var res = Result[seq[byte], string].err("not yet")
      # Poll the drain the way the FFI loop does.
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
      check st.registerImpl("echo", echoImpl, addr box).isOk()
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
      check st.registerImpl("gate", gateImpl, addr g).isOk()
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

  test "a call past ReverseQueueDepth fails at once":
    withReverseHarness(st, 1):
      var g: GateBox
      g.lock.initLock()
      g.cond.initCond()
      check st.registerImpl("gate", gateImpl, addr g).isOk()
      let blocker = ffiReverseCall("gate", @[], 60_000)
      g.waitEntered(1) # the only worker is busy: every further call waits in the queue
      var queued = newSeq[typeof(blocker)]()
      for _ in 0 ..< ReverseQueueDepth:
        queued.add(ffiReverseCall("gate", @[], 60_000))
      check st.queueLen() == ReverseQueueDepth
      let overflow = waitFor ffiReverseCall("gate", @[], 60_000)
      check overflow.isErr()
      check "queue full" in overflow.error
      check ffiPendingReverseLen() == ReverseQueueDepth + 1 # the overflow never parked
      g.open()
      failPendingReverse("done")
      check (waitFor blocker).isErr()
      for f in queued:
        check (waitFor f).isErr()
