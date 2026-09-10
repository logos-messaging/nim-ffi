## Reverse workers under the pool's thread lifecycle. Master parks a slot's
## threads once no context is live (#156); the reverse workers are a context's
## third thread class and must follow the same policy, or every recycled slot
## would leak N threads under the C runtime. Kept apart from
## `test_ffi_reverse.nim`: that file quarantines slots on purpose, and a
## quarantined slot keeps its threads, which is exactly what this file measures.

import std/[locks, os]
import unittest2
import results
import ffi

type RevPoolLib = object

var gPool: FFIContextPool[RevPoolLib]

type ProbeBox = object
  ctx: ptr FFIContext[RevPoolLib]
  sawWorkerFlag: Atomic[bool]

proc probeImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## Reports the thread marker the pool's idle reap reads, then answers.
  let p = cast[ptr ProbeBox](userData)
  p[].sawWorkerFlag.store(onReverseWorker)
  discard submitReverseReply(p[].ctx, callId, RET_OK, nil, 0)

registerReqFFI(ProbeRequest, lib: ptr FFIContext[RevPoolLib]):
  proc(): Future[Result[string, string]] {.async.} =
    let r = await ffiReverseCall("probe", @[], 5000)
    if r.isErr():
      return err(r.error)
    return ok("probed")

type Waiter = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint

proc waiterCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let w = cast[ptr Waiter](userData)
  acquire(w[].lock)
  if retCode != RET_STALE_WARN:
    w[].retCode = retCode
    w[].called = true
    signal(w[].cond)
  release(w[].lock)

template setupWaiter(name: untyped) =
  var name: Waiter
  name.lock.initLock()
  name.cond.initCond()
  defer:
    name.cond.deinitCond()
    name.lock.deinitLock()

proc await(w: var Waiter) =
  acquire(w.lock)
  while not w.called:
    wait(w.cond, w.lock)
  release(w.lock)

suite "reverse workers follow the slot's threads":
  test "the last recycle parks the slot and stops its reverse workers":
    let ctx = gPool.createFFIContext().valueOr:
      check false
      return
    var probe = ProbeBox(ctx: ctx)
    ctx[].reverse.setImpl("probe", probeImpl, addr probe)
    check ctx[].reverse.workersStarted()

    check gPool.recycleFFIContext(ctx).isOk()
    check not ctx[].reverse.workersStarted()
    check ctx[].reverse.leakedWorkers == 0

  test "a slot served again restarts its workers lazily, and they still run":
    setupWaiter(w)
    let ctx = gPool.createFFIContext().valueOr:
      check false
      return
    # A parked slot comes back with no workers until an impl is registered.
    check not ctx[].reverse.workersStarted()
    var probe = ProbeBox(ctx: ctx)
    ctx[].reverse.setImpl("probe", probeImpl, addr probe)
    check ctx[].reverse.workersStarted()

    check sendRequestToFFIThread(ctx, ProbeRequest.ffiNewReq(waiterCb, addr w)).isOk()
    w.await()
    check w.retCode == RET_OK
    # The impl ran on a reverse worker: `onReverseWorker` is what keeps the
    # pool's idle reap from joining the thread a host impl calls teardown from.
    check probe.sawWorkerFlag.load()
    check gPool.recycleFFIContext(ctx).isOk()

  test "the reap marker is false on a host thread":
    check not onReverseWorker

## A host implementation may call any export, teardown included. `reapIfIdle`
## refuses to run on one of the library's own threads; `<lib>_shutdown` has no
## such guard, so `stopReverseWorkers` also refuses to join the worker it is
## running on — either way the call returns instead of hanging on a self-join.
type SuicideBox = object
  ctx: ptr FFIContext[RevPoolLib]
  returned: Atomic[bool]

proc suicideImpl(
    callId: uint64,
    argsCbor: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  let p = cast[ptr SuicideBox](userData)
  discard submitReverseReply(p[].ctx, callId, RET_OK, nil, 0)
  # Stopping the pool from inside the impl: this thread is one of the workers.
  {.cast(gcsafe).}:
    discard stopReverseWorkers(p[].ctx[].reverse, 200)
  p[].returned.store(true)

registerReqFFI(SuicideRequest, lib: ptr FFIContext[RevPoolLib]):
  proc(): Future[Result[string, string]] {.async.} =
    let r = await ffiReverseCall("suicide", @[], 5000)
    if r.isErr():
      return err(r.error)
    return ok("survived")

suite "a teardown reached from inside a host impl":
  test "stopping the workers from a worker does not join it to itself":
    setupWaiter(w)
    let ctx = gPool.createFFIContext().valueOr:
      check false
      return
    var box = SuicideBox(ctx: ctx)
    ctx[].reverse.setImpl("suicide", suicideImpl, addr box)

    check sendRequestToFFIThread(ctx, SuicideRequest.ffiNewReq(waiterCb, addr w)).isOk()
    w.await()
    check w.retCode == RET_OK
    for _ in 0 ..< 500:
      if box.returned.load():
        break
      os.sleep(1)
    check box.returned.load() # the stop returned instead of hanging
    check ctx[].reverse.leakedWorkers >= 1 # this worker could not be joined
    # The slot is unusable now (its workers are gone); quarantine it rather than
    # hand it back to the pool.
    ctx.lifecycle.store(CtxLifecycle.RecycleFailed)
