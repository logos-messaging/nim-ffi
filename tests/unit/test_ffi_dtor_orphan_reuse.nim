## `TeardownTimeout` cuts a `{.ffiDtor.}` short and abandons the async work it did not cancel; the orphans still run on the FFI thread's dispatcher, chronos cannot cancel every future of a thread, so the slot must quarantine instead of serve the next owner.

## The orphan here ticks, fires an event and writes a sentinel through the `ptr` it kept to its library; on a reused slot that becomes cross-owner events and a write into the next owner's library object.

## Under `NIM_FFI_SAN=asan` the "library is not freed" case is also the use-after-free case: a slot that goes back into service frees the library under the live orphan, and the next sentinel write lands in the freed block; quarantine frees nothing, so the run stays clean.

## The sibling .cfg cuts both timeouts for every suite here.

import std/[atomics, os]
import unittest2
import results
import ffi

type OrphanLib = object
  canary: int64

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void liborphanlibNimMain(void) {}".}

declareLibrary("orphanlib", OrphanLib)

const
  CtorCanary = 0x1111_1111'i64
  OrphanSentinel = 0x0DEA_D0DE'i64
  OrphanEvent = "orphan_evt"
  MaxIncarnations = 8

type OrphanConfig {.ffi.} = object
  dummy: int

var
  # Per incarnation, so an orphan leaked by an earlier test cannot move the counters a later one asserts on.
  gTicks: array[MaxIncarnations, Atomic[int]]
  gStop: array[MaxIncarnations, Atomic[bool]]
  gRunning: array[MaxIncarnations, Atomic[bool]]
  gIncarnation: Atomic[int]
  gLoopThreadId: Atomic[int]
  gHandlerThreadId: Atomic[int]
  gArmSentinel: Atomic[bool]
  gLibPtr: Atomic[pointer]
  gTeardownHangs: Atomic[bool]
  gTeardownIgnoresCancel: Atomic[bool]
  gTeardownHold: Atomic[bool]
  gTeardownRan: Atomic[bool]
  gInjected: Atomic[int]
  gReplied: Atomic[bool]

proc watchdogBody(timeoutMs: int) {.thread.} =
  ## A wedged recycle would hang the file rather than fail a check.
  os.sleep(timeoutMs)
  echo "watchdog: a recycle or a drain never returned"
  quit(1)

var watchdog: Thread[int]
createThread(watchdog, watchdogBody, 120_000)

proc orphanTick(id: int) {.async.} =
  ## The offspring a library leaves behind when the timeout cuts its teardown: spawned on the FFI thread's dispatcher, and only the dtor stops it.
  gLoopThreadId.store(getThreadId())
  gRunning[id].store(true)
  while not gStop[id].load():
    await sleepAsync(10.milliseconds)
    gTicks[id].atomicInc()
    try:
      dispatchFFIEventCbor(OrphanEvent, id)
    except CatchableError:
      discard
    if gArmSentinel.load():
      let lib = cast[ptr OrphanLib](gLibPtr.load())
      if not lib.isNil():
        lib[].canary = OrphanSentinel
  gRunning[id].store(false)

proc orphanlib_create*(
    config: OrphanConfig
): Future[Result[OrphanLib, string]] {.ffiCtor.} =
  return ok(OrphanLib(canary: CtorCanary))

proc orphanlib_spawn*(lib: OrphanLib): Future[Result[int, string]] {.ffi.} =
  ## Spawns the loop the way a library would: on the FFI thread, unawaited.
  asyncSpawn orphanTick(gIncarnation.load())
  return ok(1)

proc orphanlib_ping*(lib: OrphanLib): Future[Result[int, string]] {.ffi.} =
  ## Records the thread that served the call, so a reused thread pair is visible.
  gHandlerThreadId.store(getThreadId())
  return ok(1)

proc waitHold() {.async.} =
  while gTeardownHold.load():
    await sleepAsync(10.milliseconds)

proc orphanlib_destroy*(lib: OrphanLib): Future[void] {.ffiDtor.} =
  ## Three shapes: `gTeardownHangs` sleeps past every timeout and `TeardownTimeout` cuts it short; `gTeardownIgnoresCancel` blocks the cancel, so the caller's own wait expires first; the default stops its offspring and awaits it, the contract a dtor must meet.
  if gTeardownIgnoresCancel.load():
    await noCancel(waitHold())
  elif gTeardownHangs.load():
    await sleepAsync(TeardownTimeout + 60.seconds)
  else:
    let id = gIncarnation.load()
    gStop[id].store(true)
    while gRunning[id].load():
      await sleepAsync(5.milliseconds)
  gTeardownRan.store(true)

proc noopCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

proc replyCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  gReplied.store(true)

proc injectCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## The next owner registers this: a delivery here is an event of a past owner.
  gInjected.atomicInc()

proc encodedPtr(bytes: var seq[byte]): ptr byte =
  if bytes.len == 0:
    nil
  else:
    cast[ptr byte](addr bytes[0])

proc waitFlag(flag: var Atomic[bool], timeoutMs = 5000): bool =
  let deadline = Moment.now() + timeoutMs.milliseconds
  while not flag.load():
    if Moment.now() >= deadline:
      return false
    os.sleep(5)
  true

proc waitTicks(id: int, want: int, timeoutMs = 5000): bool =
  let deadline = Moment.now() + timeoutMs.milliseconds
  while gTicks[id].load() < want:
    if Moment.now() >= deadline:
      return false
    os.sleep(5)
  true

proc waitSlotFree[T](ctx: ptr FFIContext[T]) =
  ## `requestRecycle` returns on the done signal, one step before the FFI thread releases the claim (the fire must come first, or a thread that claims the slot would take it as its own answer); wait that step out before a check that needs a free slot.
  let deadline = Moment.now() + 5.seconds
  while ctx.isInUse() and Moment.now() < deadline:
    os.sleep(1)

proc createCtxWithLib(): ptr FFIContext[OrphanLib] =
  ## Spins up a context and waits on `libReady`, the flag the teardown gates on.
  var cfg = cborEncode(OrphanlibCreateCtorReq(config: OrphanConfig(dummy: 0)))
  let token = orphanlib_create(encodedPtr(cfg), cfg.len.csize_t, noopCallback, nil)
  if token.isNil():
    return nil
  let ctx = OrphanLibFFIPool.resolveCtx(token)
  var tries = 0
  while not ctx[].libReady.load() and tries < 500:
    os.sleep(5)
    inc tries
  ctx

proc callSpawn(ctx: ptr FFIContext[OrphanLib]): bool =
  gReplied.store(false)
  var rb = cborEncode(OrphanlibSpawnReq())
  if orphanlib_spawn(ctx.ffiToken(), replyCallback, nil, encodedPtr(rb), rb.len.csize_t) !=
      RET_OK:
    return false
  waitFlag(gReplied)

proc callPing(ctx: ptr FFIContext[OrphanLib]): bool =
  gReplied.store(false)
  var rb = cborEncode(OrphanlibPingReq())
  if orphanlib_ping(ctx.ffiToken(), replyCallback, nil, encodedPtr(rb), rb.len.csize_t) !=
      RET_OK:
    return false
  waitFlag(gReplied)

# The quarantined slot outlives its test: the next suite compares against it, and its orphan never stops.
var gQuarantined: ptr FFIContext[OrphanLib]

suite "a {.ffiDtor.} that stops its offspring":
  # Runs first: no orphan is alive yet, so a clean recycle is observable.
  test "the slot is reused and the loop is gone":
    gTeardownHangs.store(false)
    gTeardownRan.store(false)
    gIncarnation.store(0)

    let ctx = createCtxWithLib()
    check not ctx.isNil()
    check callSpawn(ctx)
    check waitTicks(0, 1)

    check OrphanLibFFIPool.recycleFFIContext(ctx).isOk()
    check gTeardownRan.load()
    check not gRunning[0].load()

    waitSlotFree(ctx)
    let settled = gTicks[0].load()
    os.sleep(60)
    check gTicks[0].load() == settled

    # Lowest free slot wins, so a fresh slot here would prove nothing.
    gTeardownRan.store(false)
    let next = createCtxWithLib()
    check next == ctx
    check not next[].myLib.isNil()
    if not next[].myLib.isNil():
      check next[].myLib.canary == CtorCanary
    check OrphanLibFFIPool.recycleFFIContext(next).isOk()
    check gTeardownRan.load()

suite "a {.ffiDtor.} cut short by TeardownTimeout":
  test "the recycle fails and the abandoned library is kept":
    gTeardownHangs.store(true)
    gTeardownRan.store(false)
    gIncarnation.store(1)

    let ctx = createCtxWithLib()
    check not ctx.isNil()
    # The stale `ptr T` a library would hold on to; the orphan writes through it.
    gLibPtr.store(cast[pointer](ctx[].myLib))
    check callSpawn(ctx)
    check waitTicks(1, 1)

    let t0 = Moment.now()
    let res = OrphanLibFFIPool.recycleFFIContext(ctx)
    let elapsed = Moment.now() - t0
    gTeardownHangs.store(false)

    # The timeout ended the teardown, not an early bail and not a completed body.
    check elapsed >= TeardownTimeout
    check elapsed < RecycleWaitTimeout
    check not gTeardownRan.load()
    # An incomplete teardown is a failed recycle, not a silent success.
    check res.isErr()

    # The orphan outlived the dtor: that is why the slot cannot go back.
    check gRunning[1].load()
    let before = gTicks[1].load()
    check waitTicks(1, before + 3)

    # Quarantine keeps the library alive, so the orphan's `ptr` stays valid; the nil guard keeps a runtime that frees it from a segfault here.
    check not ctx[].myLib.isNil()
    if not ctx[].myLib.isNil():
      check ctx[].myLib.canary == CtorCanary

    # Terminal: every later caller gets the same answer.
    check OrphanLibFFIPool.recycleFFIContext(ctx).isErr()
    check OrphanLibFFIPool.quarantinedSlots() == 1
    gQuarantined = ctx

  test "the next owner gets another slot and never sees the orphan":
    check not gQuarantined.isNil()
    gTeardownHangs.store(false)
    gTeardownRan.store(false)
    gIncarnation.store(2)
    gInjected.store(0)

    let next = createCtxWithLib()
    check not next.isNil()
    check next != gQuarantined

    # Same event name as the orphan fires, on the new owner's registry.
    check addEventListener(next[].eventRegistry, OrphanEvent, injectCallback, nil) > 0
    check callPing(next)
    # A reused slot would have served this call on the orphan's own thread.
    check gHandlerThreadId.load() != gLoopThreadId.load()

    # Let the orphan fire several times against the live listener.
    let before = gTicks[1].load()
    check waitTicks(1, before + 3)
    check gInjected.load() == 0

    # The sentinel write must not reach the next owner's library: on a reused slot `freeLib` frees the object, the next ctor gets the same block back, and the write lands in the library of this context.
    gArmSentinel.store(true)
    let armed = gTicks[1].load()
    check waitTicks(1, armed + 3)
    gArmSentinel.store(false)
    check not next[].myLib.isNil()
    if not next[].myLib.isNil():
      check next[].myLib.canary == CtorCanary

    check OrphanLibFFIPool.recycleFFIContext(next).isOk()
    check gTeardownRan.load()

  test "the abandoned library is not freed under the orphan":
    # Arm before the recycle and allocate no context afterwards: a runtime that frees the library puts the orphan's next write in the freed block, which the asan job reports as a heap-use-after-free (an arm after the next owner exists hits the reallocated block; the test above covers that).
    gTeardownHangs.store(true)
    gTeardownRan.store(false)
    gIncarnation.store(4)

    let ctx = createCtxWithLib()
    check not ctx.isNil()
    gLibPtr.store(cast[pointer](ctx[].myLib))
    check callSpawn(ctx)
    check waitTicks(4, 1)

    gArmSentinel.store(true)
    let res = OrphanLibFFIPool.recycleFFIContext(ctx)
    gTeardownHangs.store(false)
    check res.isErr()

    let armed = gTicks[4].load()
    check waitTicks(4, armed + 3)
    gArmSentinel.store(false)

    # The orphan wrote into its own library, which quarantine keeps alive.
    check not ctx[].myLib.isNil()
    if not ctx[].myLib.isNil():
      check ctx[].myLib.canary == OrphanSentinel

suite "quarantine after the caller stopped waiting":
  test "a teardown that finishes past RecycleWaitTimeout does not release the slot":
    # A teardown that blocks the cancel outlasts the caller's wait; the caller saw a failed recycle, so the slot must not come back when the body ends.
    gTeardownIgnoresCancel.store(true)
    gTeardownHold.store(true)
    gTeardownRan.store(false)
    gIncarnation.store(3)

    let ctx = createCtxWithLib()
    check not ctx.isNil()
    check callSpawn(ctx)
    check waitTicks(3, 1)

    let quarantinedBefore = OrphanLibFFIPool.quarantinedSlots()
    let t0 = Moment.now()
    let res = OrphanLibFFIPool.recycleFFIContext(ctx)
    let elapsed = Moment.now() - t0
    check res.isErr()
    check elapsed >= RecycleWaitTimeout

    # Release the body: it completes, but long after the caller gave up.
    gTeardownHold.store(false)
    check waitFlag(gTeardownRan)
    gTeardownIgnoresCancel.store(false)
    os.sleep(100)
    check OrphanLibFFIPool.quarantinedSlots() == quarantinedBefore + 1

    # Nothing can bring a quarantined slot back, so the pool never offers it.
    for _ in 0 .. 2:
      let other = createCtxWithLib()
      check not other.isNil()
      check other != ctx
      check other != gQuarantined
      gTeardownRan.store(false)
      check OrphanLibFFIPool.recycleFFIContext(other).isOk()
      check gTeardownRan.load()
