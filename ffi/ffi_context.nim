## FFIContext type plus lifecycle (init / signal-stop / join / destroy).
##
## The per-thread bodies live in `ffi_thread.nim` and `event_thread.nim`,
## included below so the thread code can access the private FFIContext
## fields without forcing them through a public surface.

{.passc: "-fPIC".}

import std/[atomics, locks, options, tables]
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

type FFIContext*[T] = object
  myLib*: ptr T # main library object (Waku, LibP2P, SDS, …)
  ffiThread: Thread[(ptr FFIContext[T])]
  eventThread: Thread[(ptr FFIContext[T])]
  reqQueueBank: RequestQueueBank # mutex-guarded MPSC ingress from foreign threads
  reqSignal: ThreadSignalPtr # wakes the FFI thread on enqueue
  stopSignal: ThreadSignalPtr
  threadExitSignal: ThreadSignalPtr
    # bounds destroyFFIContext's wait so a blocked loop cannot hang the caller
  eventQueueSignal: ThreadSignalPtr # wakes the event thread on enqueue
  eventThreadExitSignal: ThreadSignalPtr # mirrors threadExitSignal for the event thread
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  handles*: FFIHandleRegistry # live {.ffiHandle.} objects, keyed by uint64 id
  eventQueue*: EventQueue
  ffiHeartbeat*: Atomic[int64]
    # advanced each FFI-thread loop; event thread reads for liveness
  eventQueueStuck*: Atomic[bool] # sticky overflow flag
  ffiThreadExited*: Atomic[bool]
    # set once the FFI thread (including any async {.ffiDtor.} teardown) is done;
    # keeps the event thread draining until then so teardown-emitted events land
  running: Atomic[bool] # To control when the threads are running
  registeredRequests: ptr Table[cstring, FFIRequestProc]
  staleWarnInterval*: Duration
    # Cadence of the non-terminal RET_STALE_WARN progress callback; defaults to
    # `StaleWarnInterval`. An internal runtime seam (tests tune it) — it is NOT
    # exposed to the ffi dev, there is no per-proc override.

var onFFIThread* {.threadvar.}: bool
  # Re-entrant dispatch guard for `sendRequestToFFIThread`.

const git_version* {.strdefine.} = "n/a"

const
  EventThreadTickInterval* = 1.seconds
  FFIHeartbeatStartDelay* = 10.seconds # grace window for library startup
  FFIHeartbeatStaleThreshold* = 1.seconds

const StaleWarnIntervalMs* {.intdefine: "ffiStaleWarnIntervalMs".} = 5000
  ## Cadence at which an in-flight request re-notifies its caller with a
  ## non-terminal `RET_STALE_WARN`. Fires without limit — nim-ffi never times a
  ## handler out; the caller decides what to do. 5s mirrors Android's ANR input
  ## timeout. Override with `-d:ffiStaleWarnIntervalMs=<ms>`.
const StaleWarnInterval* = StaleWarnIntervalMs.milliseconds

type FFITeardownProc*[T] = proc(lib: ptr T): Future[void] {.async.}

proc ffiTeardownHook*[T](): var FFITeardownProc[T] =
  ## Per-library teardown slot (one `{.global.}` per `T`), assigned at module init
  ## by a non-empty `{.ffiDtor.}` and awaited by the FFI thread before it exits.
  ##
  ## A runtime slot, not an overloaded `ffiTeardown` resolved via `mixin`: the
  ## constructor force-instantiates the FFI thread body before the dtor (declared
  ## later in the source) is visible, so an overload would bind the no-op default
  ## and the teardown would silently never run.
  var hook {.global.}: FFITeardownProc[T]
  hook

include ./event_thread
include ./ffi_thread

template closeAndNil(field: untyped) =
  if not field.isNil():
    ?field.close()
    field = nil

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`. Threads MUST be joined first (FFI thread
  ## drained); fields are nil'd after close so re-init on the same slot is safe.
  ## `deinitRequestQueue` frees any request raced in after the final drain.
  deinitRequestQueue(ctx[].reqQueueBank)
  deinitEventRegistry(ctx[].eventRegistry)
  deinitHandleRegistry(ctx[].handles)
  deinitEventQueue(ctx[].eventQueue)
  when defined(gcRefc):
    # ThreadSignalPtr.close() under refc traps in safeUnregisterAndCloseFd
    # → newDispatcher → rawNewObj → signal-handler re-entry (process hangs).
    # See tests/test_ffi_context.nim "destroyFFIContext refc workaround".
    # Fd leak is bounded — destroy runs once per process lifetime.
    discard
  else:
    closeAndNil(ctx.reqSignal)
    closeAndNil(ctx.stopSignal)
    closeAndNil(ctx.threadExitSignal)
    closeAndNil(ctx.eventQueueSignal)
    closeAndNil(ctx.eventThreadExitSignal)
  ok()

proc cleanUpResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Deinit + free for heap-allocated contexts.
  defer:
    freeShared(ctx)
  ctx.deinitContextResources()

template newSignalOrErr(field: untyped, name: string) =
  field = ThreadSignalPtr.new().valueOr:
    return err("couldn't create ThreadSignalPtr: " & name & ": " & $error)

proc initContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On failure, the deferred cleanup closes partial state; caller releases
  ## the slot (freeShared or pool.releaseSlot).
  # Nil first so deferred cleanup can't double-close a reused pool slot.
  ctx.reqSignal = nil
  ctx.stopSignal = nil
  ctx.threadExitSignal = nil
  ctx.eventQueueSignal = nil
  ctx.eventThreadExitSignal = nil
  initRequestQueue(ctx[].reqQueueBank)
  initEventRegistry(ctx[].eventRegistry)
  initHandleRegistry(ctx[].handles)
  initEventQueue(ctx[].eventQueue)
  ctx.ffiHeartbeat.store(0)
  ctx.eventQueueStuck.store(false)
  ctx.ffiThreadExited.store(false)
  ctx.staleWarnInterval = StaleWarnInterval

  var success = false
  defer:
    if not success:
      ctx.cleanUpResources().isOkOr:
        error "failed to clean up resources after createFFIContext failure",
          error = error

  newSignalOrErr(ctx.reqSignal, "reqSignal")
  newSignalOrErr(ctx.stopSignal, "stopSignal")
  newSignalOrErr(ctx.threadExitSignal, "threadExitSignal")
  newSignalOrErr(ctx.eventQueueSignal, "eventQueueSignal")
  newSignalOrErr(ctx.eventThreadExitSignal, "eventThreadExitSignal")

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
  # Skip onNotResponding on error: it takes reg.lock, which a back-pressuring
  # listener may hold — would deepen the stuck state into a deadlock.
  ctx.running.store(false)
  ?ctx.reqSignal.fireOrErr("reqSignal")
  ?ctx.stopSignal.fireOrErr("stopSignal")
  # Non-fatal: event thread sees running==false on the next tick anyway.
  ctx.eventQueueSignal.fireOrErr("eventQueueSignal").isOkOr:
    error "failed to signal eventQueueSignal in signalStop", error = error
  ok()

## Bound on how long stopAndJoinThreads waits for a worker thread to exit before
## leaking ctx rather than hanging the caller. Configurable because an async
## `{.ffiDtor.}` runs its teardown (e.g. `switch.stop()` over many live
## connections) on the FFI thread before it exits — a graceful shutdown can
## outlast the default, and being cut short leaks the context instead of waiting.
## Override at compile time with `-d:ffiThreadExitTimeoutMs=<ms>`.
const ThreadExitTimeoutMs* {.intdefine: "ffiThreadExitTimeoutMs".} = 1500
const ThreadExitTimeout* = ThreadExitTimeoutMs.milliseconds

proc stopAndJoinThreads*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On timeout, returns err and skips remaining joins (leaves threads live).
  ## Caller owns resource cleanup. Skips onNotResponding (same reason as signalStop).
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  ?ctx.threadExitSignal.waitExitOrErr("FFI thread", ThreadExitTimeout)
  joinThread(ctx.ffiThread)
  ?ctx.eventThreadExitSignal.waitExitOrErr("event thread", ThreadExitTimeout)
  joinThread(ctx.eventThread)
  ok()

proc clearContext[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Stops a heap-allocated FFI context.
  ctx.stopAndJoinThreads().isOkOr:
    return err("clearContext: " & $error)
  ctx.cleanUpResources().isOkOr:
    return err("cleanUpResources failed: " & $error)
  ok()
