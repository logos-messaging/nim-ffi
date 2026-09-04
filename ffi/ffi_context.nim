## FFIContext type plus lifecycle (init / signal-stop / join / destroy).

{.passc: "-fPIC".}

import std/[atomics, locks, options, os, sequtils, sysatomics, tables]
import chronicles, chronos, chronos/threadsync, results
when defined(windows):
  import chronos/osdefs
else:
  import chronos/selectors2
import
  ./ffi_types,
  ./ffi_events,
  ./ffi_handles,
  ./ffi_thread_request,
  ./ffi_request_queue,
  ./cbor_serial

export ffi_events, ffi_handles
export ffi_request_queue.RequestQueueDepth

type FFICtxToken* = distinct pointer
  ## Opaque handle the host holds for a context. Distinct from `pointer` so a raw
  ## address cannot be passed where a token belongs.

proc isNil*(token: FFICtxToken): bool {.borrow.}
proc `==`*(a, b: FFICtxToken): bool {.borrow.}

type CtxLifecycle* {.pure.} = enum
  ## Active -> RecyclePending (ffiDtor asks) -> Recycling (FFI loop drains) -> Active (slot reused) or RecycleFailed (teardown did not complete).
  Active
  RecyclePending
  Recycling
  RecycleFailed # terminal: only the recycle handler writes it, nothing clears it

type RecycleFailure* {.pure.} = enum
  ## Why a slot is quarantined. Not a string: the host reads it from another thread, and refc heaps are thread-local.
  None
  DrainTimeout ## in-flight handlers outlasted both drain rounds
  TeardownTimeout ## TeardownTimeout cancelled the `{.ffiDtor.}` body
  TeardownRaised ## the `{.ffiDtor.}` body raised
  CallerAbandoned ## the caller's own wait expired before the recycle finished

func reason*(failure: RecycleFailure): string =
  ## The `requestRecycle` error text for a quarantine.
  case failure
  of RecycleFailure.None:
    "recycle failed"
  of RecycleFailure.DrainTimeout:
    "in-flight handlers did not drain"
  of RecycleFailure.TeardownTimeout:
    "the timeout cancelled the {.ffiDtor.} teardown"
  of RecycleFailure.TeardownRaised:
    "the {.ffiDtor.} teardown raised"
  of RecycleFailure.CallerAbandoned:
    "the teardown outlasted the caller's wait"

type FFIContext*[T] = object
  myLib*: ptr T # main library object (Waku, LibP2P, SDS, …)
  myLibRefd*: bool
    # refc only: true once myLib[] (a ref) has been GC_ref'd to root it against
    # the cycle collector. Balanced by GC_unref in freeLib.
  myLibOwned*: bool
    # true once a ctor stored a createShared'd lib into myLib (vs the worker's
    # stack fallback). freeLib only frees/destroys owned libs.
  generation*: Atomic[uint]
    # Seqlock-style claim marker, never reset: even = free, odd = claimed. One CAS both claims the slot and opens the new generation, so no token can see a half-claimed slot. The host token carries the odd value it was issued under, so it stops resolving once the slot serves a new owner.
  token*: FFICtxToken
    # The opaque handle the host holds for the current claim. Written by
    # createFFIContext under the claim; read only by the owner.
  lifecycle*: Atomic[CtxLifecycle]
  recycleFailure*: Atomic[RecycleFailure]
    # Why the slot is quarantined; the recycle handler writes it with `RecycleFailed`.
  recycleAbandoned*: Atomic[bool]
    # `requestRecycle` sets this when its wait expires; a recycle that finishes later must quarantine, because the caller already saw a failure.
  recycleDoneSignal: ThreadSignalPtr
    # fired by the recycle handler once the lib is freed, just before it releases the slot; the synchronous recycleFFIContext caller waits on it.
  libReady*: Atomic[bool]
    # False until a {.ffiCtor.} stores the library. Before that, `myLib` points
    # at the default fallback of the FFI thread. For a `ref` type that fallback
    # is nil.
  ffiThread: Thread[(ptr FFIContext[T])]
  eventThread: Thread[(ptr FFIContext[T])]
  reqQueueBank: RequestQueueBank
  reqSignal: ThreadSignalPtr
  stopSignal: ThreadSignalPtr
  threadExitSignal: ThreadSignalPtr
  eventQueueSignal: ThreadSignalPtr
  eventThreadExitSignal: ThreadSignalPtr
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  handles*: FFIHandleRegistry
  eventQueue*: EventQueue
  ffiHeartbeat*: Atomic[int64]
  eventQueueStuck*: Atomic[bool]
  ffiThreadExited*: Atomic[bool]
    # set once FFI thread (incl. async {.ffiDtor.}) is done; event thread drains until then
  running: Atomic[bool]
  staleWarnInterval*: Duration

var onFFIThread* {.threadvar.}: bool
var onEventThread* {.threadvar.}: bool

const RecycleTimeoutMs* {.intdefine: "ffiRecycleTimeoutMs".} = 1500
  ## Bounds one drain round of the recycle handler. The handler runs at most two
  ## rounds: it waits for the in-flight handlers, then cancels them and waits
  ## again. Override with `-d:ffiRecycleTimeoutMs=<ms>`.
const RecycleTimeout* = RecycleTimeoutMs.milliseconds

const TeardownTimeoutMs* {.intdefine: "ffiTeardownTimeoutMs".} = 10000
  ## Cancels a `{.ffiDtor.}` teardown that overruns; a real library stop outlasts
  ## a drain round. Override with `-d:ffiTeardownTimeoutMs=<ms>`.
const TeardownTimeout* = TeardownTimeoutMs.milliseconds

const
  RecycleWaitTimeout* = 2 * RecycleTimeout + TeardownTimeout + 2.seconds
    ## Caller-side bound for synchronous recycle: both drain rounds, the teardown
    ## hook and slack, so it only fires when the worker itself is wedged. The
    ## generated C destructor blocks its caller this long — 15 s by default.
  EventThreadTickInterval* = 1.seconds
  FFIHeartbeatStartDelay* = 10.seconds
  FFIHeartbeatStaleThreshold* = 1.seconds

const StaleWarnIntervalMs* {.intdefine: "ffiStaleWarnIntervalMs".} = 5000
  ## `RET_STALE_WARN` cadence; handlers are never timed out.
const StaleWarnInterval* = StaleWarnIntervalMs.milliseconds

type FFITeardownProc*[T] = proc(lib: ptr T): Future[void] {.async.}

proc ffiTeardownHook*[T](): var FFITeardownProc[T] =
  ## Per-library teardown slot (one `{.global.}` per `T`), awaited by the FFI thread before exit.
  ## Runtime slot not an overload: an overload would bind the no-op default before the dtor is visible.
  var hook {.global.}: FFITeardownProc[T]
  hook

proc closeThreadDispatcher() =
  ## chronos leaks a thread's dispatcher; free it last, once nothing polls (nim-chronos#614).
  when defined(windows):
    if closeHandle(getThreadDispatcher().getIoHandler()) == 0:
      error "failed to close the thread's IOCP port; the handle leaks"
  else:
    getThreadDispatcher().getIoHandler().close2().isOkOr:
      error "failed to close the thread's poller; the fd leaks", err = error

include ./event_thread
include ./ffi_thread

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`. Threads MUST be joined, and only their owner may call it.
  deinitRequestQueue(ctx[].reqQueueBank)
  deinitEventRegistry(ctx[].eventRegistry)
  deinitHandleRegistry(ctx[].handles)
  deinitEventQueue(ctx[].eventQueue)
  ok()

proc drainSignal(sig: ThreadSignalPtr) =
  ## A reused slot inherits the fires of its last cycle; they wake the new threads for nothing.
  const MaxDrain = RequestQueueDepth
    ## One fire per request the last cycle could have left queued: every fire a stop strands.
  for _ in 0 ..< MaxDrain:
    let fired = sig.waitSync(ZeroDuration).valueOr:
      error "failed to drain a signal before restarting a context's threads",
        err = error
      return
    if not fired:
      return

template newSignalOrErr(field: untyped, name: string) =
  # A slot keeps its signals for the life of the process, so a rebuild reuses them.
  if field.isNil():
    field = ThreadSignalPtr.new().valueOr:
      return err("couldn't create ThreadSignalPtr: " & name & ": " & $error)

proc startContextThreads*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Brings up the FFI and event thread pair of a slot whose resources are live.
  drainSignal(ctx.reqSignal)
  drainSignal(ctx.stopSignal)
  drainSignal(ctx.eventQueueSignal)
  drainSignal(ctx.threadExitSignal)
  drainSignal(ctx.eventThreadExitSignal)

  ctx.ffiThreadExited.store(false)
  ctx.running.store(true)

  try:
    createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    return err("failed to create the FFI thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.eventThread, eventThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    # Join ffiThread before the caller cleans up state it is waiting on.
    ctx.running.store(false)
    let fireRes = ctx.reqSignal.fireSync()
    if fireRes.isErr():
      error "failed to signal ffiThread during event-thread cleanup",
        error = fireRes.error
    joinThread(ctx.ffiThread)
    return err("failed to create the event thread: " & getCurrentExceptionMsg())

  ok()

proc initContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On failure, deferred cleanup closes partial state; caller releases the slot.
  ctx.myLibOwned = false
  ctx.myLibRefd = false
  ctx.lifecycle.store(CtxLifecycle.Active)
  ctx.recycleFailure.store(RecycleFailure.None)
  ctx.recycleAbandoned.store(false)
  initRequestQueue(ctx[].reqQueueBank)
  initEventRegistry(ctx[].eventRegistry)
  initHandleRegistry(ctx[].handles)
  initEventQueue(ctx[].eventQueue)
  ctx.ffiHeartbeat.store(0)
  ctx.libReady.store(false)
  ctx.eventQueueStuck.store(false)
  ctx.ffiThreadExited.store(false)
  ctx.staleWarnInterval = StaleWarnInterval

  var success = false
  defer:
    if not success:
      # `ctx` is a pool slot the caller owns; close what was opened, never free it.
      ctx.deinitContextResources().isOkOr:
        error "failed to clean up resources after createFFIContext failure",
          error = error

  newSignalOrErr(ctx.reqSignal, "reqSignal")
  newSignalOrErr(ctx.stopSignal, "stopSignal")
  newSignalOrErr(ctx.threadExitSignal, "threadExitSignal")
  newSignalOrErr(ctx.eventQueueSignal, "eventQueueSignal")
  newSignalOrErr(ctx.eventThreadExitSignal, "eventThreadExitSignal")
  newSignalOrErr(ctx.recycleDoneSignal, "recycleDoneSignal")

  ?ctx.startContextThreads()

  success = true
  ok()

proc fireOrErr(sig: ThreadSignalPtr, name: string): Result[void, string] =
  let fired = sig.fireSync().valueOr:
    return err("error signaling: " & name & ": " & $error)
  if not fired:
    return err("failed to signal: " & name & " on time")
  ok()

proc waitExitOrErr(
    sig: ThreadSignalPtr, name: string, timeout: Duration
): Result[void, string] =
  let exited = sig.waitSync(timeout).valueOr:
    return err("error waiting for exit: " & name & ": " & $error)
  if not exited:
    return err("did not exit in time: " & name & " (leaking ctx to avoid hang)")
  ok()

proc signalStop*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  # Skip onNotResponding on error: it runs the listeners here, and a stuck one blocks the stop.
  ctx.running.store(false)
  ?ctx.reqSignal.fireOrErr("reqSignal")
  ?ctx.stopSignal.fireOrErr("stopSignal")
  ctx.eventQueueSignal.fireOrErr("eventQueueSignal").isOkOr:
    error "failed to signal eventQueueSignal in signalStop", error = error
  ok()

proc tryClaim*[T](ctx: ptr FFIContext[T]): bool =
  ## Claims a free pooled context by moving its generation from even to odd: the slot keeps its address, so one CAS both claims it and opens the generation that separates this owner from the last.
  let generation = ctx.generation.load()
  if (generation and 1) == 1:
    return false
  var expected = generation
  ctx.generation.compareExchange(expected, generation + 1)

proc ffiToken*[T](ctx: ptr FFIContext[T]): FFICtxToken =
  ## The opaque handle the host holds for `ctx`. Never a raw address: an address
  ## outlives the claim it was handed out under.
  ctx.token

proc releaseClaim*[T](ctx: ptr FFIContext[T]) =
  ## Back to even, which is a generation no token was ever issued under.
  ctx.generation.atomicInc()

proc isInUse*[T](ctx: ptr FFIContext[T]): bool =
  (ctx.generation.load() and 1) == 1

proc currentGeneration*[T](ctx: ptr FFIContext[T]): uint =
  ## The generation of the live claim; a request carries it so the FFI thread can drop it once the slot changes owner.
  ctx.generation.load()

proc markAsActive*[T](ctx: ptr FFIContext[T]) =
  ## Reused context: its worker threads are still alive; re-arm for requests.
  ctx.lifecycle.store(CtxLifecycle.Active)

proc awaitClaimReleased[T](ctx: ptr FFIContext[T]): bool =
  ## `finishRecycle` releases the claim one step after it fires the done signal. False on timeout.
  const
    SpinRounds = 1000
    SleepRounds = 1000
      ## then 1ms apiece: a spin alone starves the releasing thread on one core.
  for _ in 0 ..< SpinRounds:
    if not ctx.isInUse():
      return true
    cpuRelax()
  for _ in 0 ..< SleepRounds:
    if not ctx.isInUse():
      return true
    os.sleep(1)
  false

proc requestRecycle*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Frees the lib and releases the slot, keeping its threads for the next createFFIContext.
  var expected = CtxLifecycle.Active
  if not ctx.lifecycle.compareExchange(expected, CtxLifecycle.RecyclePending):
    return err("requestRecycle: context is not Active (already recycling)")

  ctx.recycleAbandoned.store(false)

  # A recycle that timed out can fire late. The CAS makes this the only recycle
  # in flight, so drop that stale fire before the wait below can answer to it.
  discard ctx.recycleDoneSignal.waitSync(ZeroDuration)

  let fired = ctx.reqSignal.fireSync().valueOr:
    return err("requestRecycle: failed to signal the FFI thread: " & $error)
  if not fired:
    return err("requestRecycle: failed to signal the FFI thread in time")

  let done = ctx.recycleDoneSignal.waitSync(RecycleWaitTimeout).valueOr:
    return err("requestRecycle: failed waiting for recycle: " & $error)
  if not done:
    # Quarantine, not release: this caller already saw the failure.
    ctx.recycleAbandoned.store(true)
    error "recycle did not complete in time; the pool slot is quarantined",
      timeoutMs = RecycleWaitTimeout.milliseconds
    return err("requestRecycle: recycle did not complete in time")
  if ctx.lifecycle.load() == CtxLifecycle.RecycleFailed:
    return err(
      "requestRecycle: " & ctx.recycleFailure.load().reason() &
        "; the library and the pool slot leak, and callbacks can still fire"
    )

  if not ctx.awaitClaimReleased():
    # An ok here reads as a live slot, so the idle reap is skipped and nothing triggers a later one.
    error "the recycled slot did not come free; the pool treats it as still owned"
    return err("requestRecycle: the slot did not come free")
  ok()

const ThreadExitTimeoutMs* {.intdefine: "ffiThreadExitTimeoutMs".} = 1500
  ## Per-thread exit wait; past it stopAndJoinThreads leaks the ctx rather than hangs.
const ThreadExitTimeout* = ThreadExitTimeoutMs.milliseconds

const OwnedExitTimeout* = ThreadExitTimeout + TeardownTimeout
  ## Exit wait at shutdown: an owned slot runs its `{.ffiDtor.}` on the way out, with no retry.

proc stopAndJoinThreads*[T](
    ctx: ptr FFIContext[T], timeout = ThreadExitTimeout
): Result[void, string] =
  ## On timeout, returns err and skips remaining joins (leaves threads live); caller cleans up.
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  ?ctx.threadExitSignal.waitExitOrErr("FFI thread", timeout)
  joinThread(ctx.ffiThread)
  ?ctx.eventThreadExitSignal.waitExitOrErr("event thread", timeout)
  joinThread(ctx.eventThread)
  ok()
