## FFIContext type plus lifecycle (init / signal-stop / join / destroy).

{.passc: "-fPIC".}

import std/[atomics, locks, options, sequtils, tables]
import chronicles, chronos, chronos/threadsync, results
import
  ./ffi_types,
  ./ffi_events,
  ./ffi_handles,
  ./ffi_thread_request,
  ./ffi_request_queue,
  ./logging,
  ./cbor_serial

export ffi_events, ffi_handles
export ffi_request_queue.RequestQueueDepth

type FFICtxToken* = distinct pointer
  ## Opaque handle the host holds for a context. Distinct from `pointer` so a raw
  ## address cannot be passed where a token belongs.

proc isNil*(token: FFICtxToken): bool {.borrow.}
proc `==`*(a, b: FFICtxToken): bool {.borrow.}

type CtxLifecycle* {.pure.} = enum
  ## Active -> RecyclePending (ffiDtor asks) -> Recycling (FFI loop drains) -> Active (slot reused) or RecycleFailed (drain timed out).
  Active
  RecyclePending
  Recycling
  RecycleFailed # terminal: only the recycle handler writes it, nothing clears it

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
  registeredRequests: ptr Table[cstring, FFIRequestProc]
  staleWarnInterval*: Duration

var onFFIThread* {.threadvar.}: bool

const git_version* {.strdefine.} = "n/a"

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

include ./event_thread
include ./ffi_thread

template closeAndNil(field: untyped) =
  if not field.isNil():
    ?field.close()
    field = nil

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`. Threads MUST be joined first; fields nil'd after close.
  deinitRequestQueue(ctx[].reqQueueBank)
  deinitEventRegistry(ctx[].eventRegistry)
  deinitHandleRegistry(ctx[].handles)
  deinitEventQueue(ctx[].eventQueue)
  when defined(gcRefc):
    # ThreadSignalPtr.close() under refc hangs via signal-handler re-entry; the
    # recycle pool makes full destroy rare, so the leaked fd stays bounded.
    discard
  else:
    closeAndNil(ctx.reqSignal)
    closeAndNil(ctx.stopSignal)
    closeAndNil(ctx.threadExitSignal)
    closeAndNil(ctx.eventQueueSignal)
    closeAndNil(ctx.eventThreadExitSignal)
    closeAndNil(ctx.recycleDoneSignal)
  ok()

template newSignalOrErr(field: untyped, name: string) =
  field = ThreadSignalPtr.new().valueOr:
    return err("couldn't create ThreadSignalPtr: " & name & ": " & $error)

proc initContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On failure, deferred cleanup closes partial state; caller releases the slot.
  # Nil first so deferred cleanup can't double-close a reused pool slot.
  ctx.reqSignal = nil
  ctx.stopSignal = nil
  ctx.threadExitSignal = nil
  ctx.eventQueueSignal = nil
  ctx.eventThreadExitSignal = nil
  ctx.recycleDoneSignal = nil
  ctx.myLibOwned = false
  ctx.myLibRefd = false
  ctx.lifecycle.store(CtxLifecycle.Active)
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

  ctx.registeredRequests = addr ffi_types.registeredRequests

  ctx.running.store(true)

  try:
    createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    return err("failed to create the FFI thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.eventThread, eventThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    # Join ffiThread before deferred cleanup closes signals it's waiting on.
    ctx.running.store(false)
    let fireRes = ctx.reqSignal.fireSync()
    if fireRes.isErr():
      error "failed to signal ffiThread during event-thread cleanup",
        error = fireRes.error
    joinThread(ctx.ffiThread)
    return err("failed to create the event thread: " & getCurrentExceptionMsg())

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
  # Skip onNotResponding on error: it takes reg.lock a stuck listener may hold (deadlock risk).
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

proc requestRecycle*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Ask the FFI thread to drain, free the lib and release the slot, WITHOUT
  ## stopping its worker/event threads, so the next createFFIContext reuses them.
  ## Synchronous: waits on recycleDoneSignal. No fd churn -> no select() limit.
  ## An err means the caller must keep the callback userData of every in-flight
  ## request alive: teardown did not complete. A request the host races against its own recycle is rejected or silently dropped, never answered.
  var expected = CtxLifecycle.Active
  if not ctx.lifecycle.compareExchange(expected, CtxLifecycle.RecyclePending):
    return err("requestRecycle: context is not Active (already recycling)")

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
    return err("requestRecycle: recycle did not complete in time")
  if ctx.lifecycle.load() == CtxLifecycle.RecycleFailed:
    return err(
      "requestRecycle: in-flight handlers did not drain; the library and the pool " &
        "slot are leaked, and their callbacks can still fire"
    )
  ok()

## Per-thread exit wait before stopAndJoinThreads leaks ctx rather than hanging. Kept
## short so a wedged worker fails fast; raise it past `ffiTeardownTimeoutMs` for a slow
## `{.ffiDtor.}`. Override `-d:ffiThreadExitTimeoutMs=<ms>`.
const ThreadExitTimeoutMs* {.intdefine: "ffiThreadExitTimeoutMs".} = 1500
const ThreadExitTimeout* = ThreadExitTimeoutMs.milliseconds

proc stopAndJoinThreads*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On timeout, returns err and skips remaining joins (leaves threads live); caller cleans up.
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  ?ctx.threadExitSignal.waitExitOrErr("FFI thread", ThreadExitTimeout)
  joinThread(ctx.ffiThread)
  ?ctx.eventThreadExitSignal.waitExitOrErr("event thread", ThreadExitTimeout)
  joinThread(ctx.eventThread)
  ok()
