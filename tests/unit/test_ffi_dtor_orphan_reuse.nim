## A `{.ffiDtor.}` cut short by `TeardownTimeout` abandons whatever async work it
## never cancelled. Those orphans keep running on the FFI thread's dispatcher —
## chronos offers no way to cancel every future of a thread — so the slot must be
## quarantined instead of handed to the next owner.
##
## The orphan here ticks, fires an event and writes a sentinel through the `ptr`
## it kept to its library, which is what a reused slot turns into: cross-owner
## events and a write into the next owner's library object.
##
## Under `NIM_FFI_SAN=asan` the "the abandoned library is not freed" case is also
## the use-after-free case: a slot that goes back into service frees the library
## under the live orphan, and the orphan's next sentinel write lands in the freed
## block. Nothing is freed once the slot is quarantined, so the run stays clean.
##
## test_ffi_dtor_orphan_reuse.nim.cfg cuts both timeouts for every suite here.

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
  # Per incarnation, so an orphan leaked by an earlier test cannot move the
  # counters a later one asserts on.
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
  ## The offspring a real library leaves behind when its teardown is cut short:
  ## spawned on the FFI thread's dispatcher, stopped by nothing but the dtor.
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
  ## Three shapes: `gTeardownHangs` sleeps past every timeout and is cut short by
  ## `TeardownTimeout`; `gTeardownIgnoresCancel` cannot be cut short at all, so
  ## the caller's own wait expires first; the default stops its offspring and
  ## awaits it, which is the contract a dtor must meet.
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
  ## Registered by the next owner: a delivery here is an event of a past one.
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
  ## `requestRecycle` returns once the recycle fired its done signal, which is
  ## one step before the FFI thread releases the claim (the fire has to come
  ## first, or a thread claiming the slot would take it as its own answer). Wait
  ## that step out before a check that depends on the slot being free.
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

# The quarantined slot outlives the test that made it: the next suite compares
# against it, and its orphan never stops.
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

    # The timeout ended the teardown, not an early bail or the body finishing.
    check elapsed >= TeardownTimeout
    check elapsed < RecycleWaitTimeout
    check not gTeardownRan.load()
    # An incomplete teardown is a failed recycle, not a silent success.
    check res.isErr()

    # The orphan outlived the dtor: that is why the slot cannot go back.
    check gRunning[1].load()
    let before = gTicks[1].load()
    check waitTicks(1, before + 3)

    # Quarantine keeps the library alive, so the orphan's `ptr` stays valid.
    # Guarded: a runtime that frees it leaves `myLib` nil, and the file has more
    # to report than one segfault.
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

    # The orphan's sentinel write must not reach the next owner's library. On a
    # reused slot `freeLib` freed that object and the next ctor is handed the same
    # block back, so the write lands in the library serving this context.
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
    # Armed before the recycle, with nothing allocating a context afterwards, so
    # on a runtime that frees the library the orphan's next write lands in the
    # freed block: this is the case the `NIM_FFI_SAN=asan` job reports as a
    # heap-use-after-free. (Arming *after* the next owner exists instead hits the
    # reallocated block, which the test above covers.)
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
    # An uncancellable teardown outlasts the caller's wait, so the recycle it
    # reported as failed must not hand the slot back when the body finally ends.
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
