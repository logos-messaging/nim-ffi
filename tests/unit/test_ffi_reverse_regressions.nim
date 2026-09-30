## Regressions for the PR #154 review findings (F1-F7, N1). Each test failed
## before its fix; the comments say how.

import std/[atomics, locks, monotimes, os, osproc, strtabs, strutils, times]
import unittest2
import results
import ffi
import ./reverse_leak_child
import ffi/codegen/[c, meta]

type RevRegLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void librevregNimMain(void) {}".}

declareLibrary("revreg", RevRegLib)

## Child mode: a probe that may abort runs in a re-exec of this binary.

const ChildEnv = "REVREG_CHILD"

if getEnv(ChildEnv) == "reply_len_overflow":
  let ctx = RevRegLibFFIPool.createFFIContext().valueOr:
    quit(2)
  var b = [byte 0]
  let rc =
    revreg_reverse_reply(ctx.ffiToken(), 1'u64, RET_OK, addr b[0], csize_t(high(uint)))
  echo "rc=", rc
  quit(if rc == REVERSE_ACCEPTED: 3 else: 0)

proc runChild(mode: string): tuple[output: string, exitCode: int] =
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env[ChildEnv] = mode
  return execCmdEx(quoteShell(getAppFilename()), env = env)

## Host impls and their boxes.

proc nopImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  discard

type GateBox = object
  lock: Lock
  cond: Cond
  entered: int
  exited: int
  release: bool

proc initGate(g: var GateBox) =
  g.lock.initLock()
  g.cond.initCond()

proc gateImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## Parks the worker until the test releases it: a blocking host impl.
  let g = cast[ptr GateBox](userData)
  acquire(g[].lock)
  g[].entered.inc()
  broadcast(g[].cond)
  while not g[].release:
    wait(g[].cond, g[].lock)
  g[].exited.inc()
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

proc stillInside(g: var GateBox): bool =
  acquire(g.lock)
  result = g.entered > g.exited
  release(g.lock)

proc openLater(g: ptr GateBox) {.thread.} =
  os.sleep(300)
  g[].open()

type UnregBox = object
  st: ptr FFIReverseState
  gate: ptr GateBox
  victimInsideAtReturn: Atomic[int] # -1 until set_impl returned
  done: Atomic[bool]

proc unregImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## Unregisters "victim" from inside a dispatch, then reports whether it still runs.
  let b = cast[ptr UnregBox](userData)
  b[].st[].setImpl("victim", nil, nil)
  b[].victimInsideAtReturn.store(if b[].gate[].stillInside(): 1 else: 0)
  b[].done.store(true)

type TwiceBox = object
  st: ptr FFIReverseState

proc replyTwiceImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  let b = cast[ptr TwiceBox](userData)
  var first = [byte 1]
  var second = [byte 2]
  discard b[].st[].pushReply(callId, RET_OK, addr first[0], 1)
  discard b[].st[].pushReply(callId, RET_OK, addr second[0], 1)

var raceSt: FFIReverseState
var raceGate: GateBox
var raceStopped: Atomic[int]

proc concurrentStop(timeoutMs: int) {.thread.} =
  {.cast(gcsafe).}:
    let r = stopReverseWorkers(raceSt, timeoutMs)
    discard raceStopped.fetchAdd(r.stopped)

proc concurrentStopProbe(): int =
  ## Two stops race over two wedged workers that are then released together.
  initReverseState(raceSt)
  initGate(raceGate)
  if not raceSt.startReverseWorkers(2):
    return 2
  raceSt.setImpl("gate", gateImpl, addr raceGate)
  ffiCurrentReverseState = addr raceSt
  let a = ffiReverseCall("gate", @[], 60_000)
  let b = ffiReverseCall("gate", @[], 60_000)
  raceGate.waitEntered(2)

  var t1, t2: Thread[int]
  createThread(t1, concurrentStop, 1000)
  createThread(t2, concurrentStop, 1000)
  os.sleep(100) # both stops are waiting on the wedged workers
  raceGate.open()
  joinThread(t1)
  joinThread(t2)
  echo "stopped=", raceStopped.load()
  failPendingReverse("stopped")
  discard waitFor a
  discard waitFor b
  return (if raceStopped.load() == 2: 0 else: 3)

if getEnv(ChildEnv) == "concurrent_stop":
  quit(concurrentStopProbe())

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

proc pumpUntil(fut: FutureBase, ms: int) =
  let deadline = getMonoTime() + initDuration(milliseconds = ms)
  while not fut.finished() and getMonoTime() < deadline:
    drainReverseReplies()
    waitFor sleepAsync(chronos.milliseconds(1))

suite "F1: set_impl waits out in-flight invocations":
  test "from inside an impl, it still waits for another worker running the same name":
    withReverseHarness(st, 2):
      var g: GateBox
      initGate(g)
      var box = UnregBox(st: addr st, gate: addr g)
      box.victimInsideAtReturn.store(-1)
      st.setImpl("victim", gateImpl, addr g)
      st.setImpl("unreg", unregImpl, addr box)

      let victimFut = ffiReverseCall("victim", @[], 5000)
      g.waitEntered(1)
      let unregFut = ffiReverseCall("unreg", @[], 5000)
      # A correct set_impl blocks until "victim" returns, so release it after a pause.
      for _ in 0 ..< 300:
        if box.done.load():
          break
        os.sleep(1)
      g.open()
      for _ in 0 ..< 2000:
        if box.done.load():
          break
        os.sleep(1)

      check box.done.load()
      # Before the fix, 1: set_impl returned while "victim" still ran on the other
      # worker, whose userData the host may already have freed.
      check box.victimInsideAtReturn.load() == 0
      failPendingReverse("test over")
      discard waitFor victimFut
      discard waitFor unregFut

  test "registering one name does not wait for an unrelated impl":
    withReverseHarness(st, 1):
      var g: GateBox
      initGate(g)
      st.setImpl("bar", gateImpl, addr g)
      let barFut = ffiReverseCall("bar", @[], 5000)
      g.waitEntered(1)

      var opener: Thread[ptr GateBox]
      createThread(opener, openLater, addr g)
      let t0 = getMonoTime()
      st.setImpl("foo", nopImpl, nil)
      let elapsedMs = (getMonoTime() - t0).inMilliseconds
      joinThread(opener)

      # Before the fix, ~300 ms: set_impl("foo") waited for "bar" to be released.
      check elapsedMs < 100
      failPendingReverse("test over")
      discard waitFor barFut

## F2 runs a real context: a handler starts its reverse call after the recycle
## already failed the parked ones.

var lateRsp: tuple[lock: Lock, cond: Cond, called: bool, retCode: cint]

proc lateCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if retCode == RET_STALE_WARN:
      return
    acquire(lateRsp.lock)
    lateRsp.retCode = retCode
    lateRsp.called = true
    signal(lateRsp.cond)
    release(lateRsp.lock)

registerReqFFI(LateReverseRequest, lib: ptr RevRegLib):
  proc(): Future[Result[string, string]] {.async.} =
    # Outlasts the recycle's failPendingReverse, then parks past RecycleTimeout.
    await sleepAsync(chronos.milliseconds(200))
    let r = await ffiReverseCall("late", @[], RecycleTimeoutMs * 2)
    if r.isErr():
      return err(r.error)
    return ok("unexpected success")

suite "F2: recycle vs a reverse call started mid-drain":
  test "a reverse call issued while the recycle drains does not stall it":
    lateRsp.lock.initLock()
    lateRsp.cond.initCond()
    let ctx = RevRegLibFFIPool.createFFIContext().valueOr:
      check false
      return
    ctx[].reverse.setImpl("late", nopImpl, nil) # never answers
    check sendRequestToFFIThread(ctx, LateReverseRequest.ffiNewReq(lateCb, nil)).isOk()
    os.sleep(50) # the handler is inside its sleepAsync

    let t0 = getMonoTime()
    let res = RevRegLibFFIPool.recycleFFIContext(ctx)
    let elapsedMs = (getMonoTime() - t0).inMilliseconds
    checkpoint("recycle: " & $res & " after " & $elapsedMs & " ms")
    check res.isOk()
    check elapsedMs < RecycleTimeoutMs

    # Keep the process alive until the parked call's own deadline answers it.
    acquire(lateRsp.lock)
    while not lateRsp.called:
      wait(lateRsp.cond, lateRsp.lock)
    release(lateRsp.lock)
    check lateRsp.retCode == RET_ERR

## F4 leaks its states on purpose (wedged workers), so they live at module level.

var stopSt: FFIReverseState
var stopGate: GateBox

suite "F4: worker stop":
  leakingTest(
    "F4: worker stop",
    "stop honours one deadline for the whole pool, not one per worker",
  ):
    initReverseState(stopSt)
    initGate(stopGate)
    check stopSt.startReverseWorkers(2)
    stopSt.setImpl("gate", gateImpl, addr stopGate)
    ffiCurrentReverseState = addr stopSt
    defer:
      ffiCurrentReverseState = nil
    let a = ffiReverseCall("gate", @[], 60_000)
    let b = ffiReverseCall("gate", @[], 60_000)
    stopGate.waitEntered(2)

    let t0 = getMonoTime()
    let stop = stopReverseWorkers(stopSt, 200)
    let elapsedMs = (getMonoTime() - t0).inMilliseconds
    check stop.leaked == 2
    # Before the fix, ~400 ms: each wedged worker gets its own 200 ms.
    check elapsedMs < 350

    stopGate.open()
    failPendingReverse("stopped")
    discard waitFor a
    discard waitFor b
    os.sleep(20)

suite "F4: concurrent stop":
  test "two stops racing join each worker exactly once":
    # Before the fix, the child died with SIGSEGV: the first stop frees `workers` while the
    # second still walks it (ffi_reverse.nim:490).
    let (output, code) = runChild("concurrent_stop")
    checkpoint(output)
    check code == 0

suite "F5: reverse_reply boundary checks":
  test "a reply_len above int.high is rejected, not a RangeDefect abort":
    let (output, code) = runChild("reply_len_overflow")
    checkpoint(output)
    check code == 0

  test "a NULL reply buffer with a non-zero length is rejected":
    let ctx = RevRegLibFFIPool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard RevRegLibFFIPool.destroyFFIContext(ctx)
    check revreg_reverse_reply(ctx.ffiToken(), 1'u64, RET_OK, nil, 16) !=
      REVERSE_ACCEPTED

suite "F7: generated C contract":
  test "the header names the REVERSE_* status codes, including workers-failed":
    let reverse = @[
      FFIReverseMeta(
        wireName: "fetch_config",
        nimProcName: "fetchConfig",
        libName: "timer",
        argsTypeName: "string",
        replyTypeName: "",
      )
    ]
    let header = generateCLibHeader(@[], @[], "timer", @[], @[], reverse, @[])
    check "REVERSE_WORKERS_FAILED" in header

  test "the timer example's {.ffiReverse.} doc comment reaches the C header":
    const headerPath =
      currentSourcePath().parentDir() / ".." / ".." / "examples" / "timer" / "c_bindings" /
      "my_timer.h"
    check "Asks the host for its wall clock" in readFile(headerPath)

suite "N1: duplicate replies (new, from validation)":
  test "the first reply submitted for a call id wins":
    withReverseHarness(st, 1):
      var box = TwiceBox(st: addr st)
      st.setImpl("twice", replyTwiceImpl, addr box)
      let fut = ffiReverseCall("twice", @[], 2000)
      pumpUntil(fut, 2000)
      let res = waitFor fut
      check res.isOk()
      # Before the fix, @[2]: the mailbox is LIFO, so the later reply is drained first.
      check res.value == @[byte 1]
