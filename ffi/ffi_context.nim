## FFIContext type plus lifecycle (init / signal-stop / join / destroy).
##
## The per-thread bodies live in `ffi_thread.nim` and `event_thread.nim`,
## included below so the thread code can access the private FFIContext
## fields without forcing them through a public surface.

{.passc: "-fPIC".}

# Embedded in a foreign host (Go/Rust/...) the host must own OS signal handling;
# Nim installing its own handlers clobbers it (e.g. Go's SIGSEGV -> sigpanic).
# Enforce -d:noSignalHandler; standalone Nim binaries opt out via -d:ffiAllowSignalHandler.
when not defined(noSignalHandler) and not defined(ffiAllowSignalHandler):
  {.
    error:
      "nim-ffi: missing required compile flag. If this library is embedded in a " &
      "host process (Go/Rust/...), build with -d:noSignalHandler so the host keeps " &
      "ownership of OS signal handlers (it needs SIGSEGV for crash recovery, stack " &
      "growth and preemption). If instead this is a standalone Nim program that owns " &
      "its own process, build with -d:ffiAllowSignalHandler."
  .}

import std/[atomics, locks, options, sequtils, tables]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import ./ffi_types, ./ffi_events, ./ffi_thread_request, ./logging, ./cbor_serial

export ffi_events

type CtxLifecycle {.pure.} = enum
  ## State machine guarding a pooled FFI context, held as an Atomic on FFIContext.
  ## The threads, signals and dispatcher kqueues are created once per slot and
  ## REUSED across acquire/release — chronos never frees a dispatcher's kqueue fd
  ## (design decision; freed only at process exit), so spawning a thread per
  ## context would leak fds unboundedly. Recycling parks the context instead.
  ## Transitions:
  ##   Active         -> RecyclePending   when the destructor is invoked
  ##   RecyclePending -> Recycling        FFI loop drains handlers, frees lib, releases slot
  ##   Recycling      -> Active           next createFFIContext reuses the slot (markAsActive)
  Active ## accepting and serving requests
  RecyclePending ## recycle requested; FFI thread loop hasn't claimed it yet
  Recycling ## FFI loop draining handlers, then frees lib + returns to pool

type FFIContext*[T] = object
  myLib*: ptr T # main library object (Waku, LibP2P, SDS, …)
  ffiThread: Thread[(ptr FFIContext[T])]
  eventThread: Thread[(ptr FFIContext[T])]
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr FFIThreadRequest]
  reqSignal: ThreadSignalPtr
  reqReceivedSignal: ThreadSignalPtr
  stopSignal: ThreadSignalPtr
  threadExitSignal: ThreadSignalPtr
    # bounds destroyFFIContext's wait so a blocked loop cannot hang the caller
  eventQueueSignal: ThreadSignalPtr # wakes the event thread on enqueue
  eventThreadExitSignal: ThreadSignalPtr # mirrors threadExitSignal for the event thread
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  eventQueue*: EventQueue
  ffiHeartbeat*: Atomic[int64]
    # advanced each FFI-thread loop; event thread reads for liveness
  eventQueueStuck*: Atomic[bool] # sticky overflow flag
  running: Atomic[bool] # To control when the threads are running
  lifecycle: Atomic[CtxLifecycle] # Active / RecyclePending / Recycling
  recycleCallback: FFICallBack
    # destructor's callback, fired by the recycle handler with the outcome:
    # RET_OK once drained, RET_ERR if it timed out. Set by requestRecycle.
  recycleUserData: pointer
  inUse: Atomic[bool]
    # whether the slot is claimed; createFFIContext claims it, the recycle
    # handler clears it once drained so the owning thread can release without
    # reaching into the pool.
  registeredRequests: ptr Table[cstring, FFIRequestProc]

var onFFIThread* {.threadvar.}: bool
  # Re-entrant dispatch guard for `sendRequestToFFIThread`.

const git_version* {.strdefine.} = "n/a"

const
  EventThreadTickInterval* = 1.seconds
  FFIHeartbeatStartDelay* = 10.seconds # grace window for library startup
  FFIHeartbeatStaleThreshold* = 1.seconds

proc tryClaim*[T](ctx: ptr FFIContext[T]): bool =
  ## Returns true if the slot was free and is now claimed, false if already in use.
  var expected = false
  ctx.inUse.compareExchange(expected, true)

proc release*[T](ctx: ptr FFIContext[T]) =
  ctx.inUse.store(false)

proc isInUse*[T](ctx: ptr FFIContext[T]): bool =
  ctx.inUse.load()

proc markAsActive*[T](ctx: ptr FFIContext[T]) =
  ## Re-arms a reused (recycled) slot to accept requests again.
  ctx.lifecycle.store(CtxLifecycle.Active)

include ./event_thread
include ./ffi_thread

template closeAndNil(field: untyped) =
  if not field.isNil():
    ?field.close()
    field = nil

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`. Threads MUST be joined first;
  ## fields are nil'd after close so re-init on the same slot is safe.
  ctx.lock.deinitLock()
  deinitEventRegistry(ctx[].eventRegistry)
  deinitEventQueue(ctx[].eventQueue)
  when defined(gcRefc):
    # ThreadSignalPtr.close() under refc traps in safeUnregisterAndCloseFd
    # → newDispatcher → rawNewObj → signal-handler re-entry (process hangs).
    # See tests/test_ffi_context.nim "destroyFFIContext refc workaround".
    # Fd leak is bounded — destroy runs once per process lifetime.
    discard
  else:
    closeAndNil(ctx.reqSignal)
    closeAndNil(ctx.reqReceivedSignal)
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
  ctx.reqReceivedSignal = nil
  ctx.stopSignal = nil
  ctx.threadExitSignal = nil
  ctx.eventQueueSignal = nil
  ctx.eventThreadExitSignal = nil
  ctx.lock.initLock()
  initEventRegistry(ctx[].eventRegistry)
  initEventQueue(ctx[].eventQueue)
  ctx.ffiHeartbeat.store(0)
  ctx.eventQueueStuck.store(false)

  var success = false
  defer:
    if not success:
      ctx.cleanUpResources().isOkOr:
        error "failed to clean up resources after createFFIContext failure",
          error = error

  newSignalOrErr(ctx.reqSignal, "reqSignal")
  newSignalOrErr(ctx.reqReceivedSignal, "reqReceivedSignal")
  newSignalOrErr(ctx.stopSignal, "stopSignal")
  newSignalOrErr(ctx.threadExitSignal, "threadExitSignal")
  newSignalOrErr(ctx.eventQueueSignal, "eventQueueSignal")
  newSignalOrErr(ctx.eventThreadExitSignal, "eventThreadExitSignal")

  ctx.registeredRequests = addr ffi_types.registeredRequests

  ctx.lifecycle.store(CtxLifecycle.Active)
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

proc reachedExitOrTimedOut(sig: ThreadSignalPtr, timeout: Duration): bool =
  ## Best-effort bounded pre-check before joining a stopping thread.
  ## Returns false ONLY on a genuine timeout (the exit signal was not observed
  ## within `timeout`, so the thread may be wedged and the caller should skip
  ## the join to avoid hanging). Returns true otherwise — including when
  ## `waitSync` itself errors: it uses `select()`, which returns EINVAL once a
  ## signal fd exceeds FD_SETSIZE under load. That error is NOT evidence the
  ## thread is stuck (it was already signaled to stop and the async event loop
  ## that drives its exit is unaffected), so we proceed to the authoritative,
  ## fd-free joinThread rather than spuriously failing teardown and leaking the
  ## pool slot.
  let waited = sig.waitSync(timeout)
  if waited.isOk() and not waited.get():
    return false # genuine timeout
  true

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

## Bound on how long clearContext waits for the FFI thread to exit before
## leaking ctx rather than hanging the caller.
const ThreadExitTimeout* = 1500.milliseconds

proc stopAndJoinThreads*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On timeout, returns err and skips remaining joins (leaves threads live).
  ## Caller owns resource cleanup. Skips onNotResponding (same reason as signalStop).
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  if not ctx.threadExitSignal.reachedExitOrTimedOut(ThreadExitTimeout):
    return err("FFI thread did not exit in time (leaking ctx to avoid hang)")
  joinThread(ctx.ffiThread)
  if not ctx.eventThreadExitSignal.reachedExitOrTimedOut(ThreadExitTimeout):
    return err("event thread did not exit in time (leaking ctx to avoid hang)")
  joinThread(ctx.eventThread)
  ok()

proc clearContext[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Stops a heap-allocated FFI context.
  ctx.stopAndJoinThreads().isOkOr:
    return err("clearContext: " & $error)
  ctx.cleanUpResources().isOkOr:
    return err("cleanUpResources failed: " & $error)
  ok()

proc requestRecycle*[T](
    ctx: ptr FFIContext[T], callback: FFICallBack, userData: pointer
): Result[void, string] =
  ## Starts the context's recycle WITHOUT stopping its worker threads, so the
  ## next createFFIContext reuses the same threads, signals and kqueue fds.
  ## The FFI thread loop drains the in-flight handlers, frees the lib, clears the
  ## per-context state and releases the slot, then fires `callback`
  ## (RET_OK drained, RET_ERR stuck). Non-blocking.
  ctx.lock.acquire()
  if ctx.lifecycle.load() != CtxLifecycle.Active:
    ctx.lock.release()
    return err("requestRecycle: context is not Active (already recycling)")
  ctx.recycleCallback = callback
  ctx.recycleUserData = userData
  ctx.lifecycle.store(CtxLifecycle.RecyclePending)
  ctx.lock.release()

  let fired = ctx.reqSignal.fireSync().valueOr:
    return err("requestRecycle: failed to signal the FFI thread: " & $error)
  if not fired:
    return err("requestRecycle: failed to signal the FFI thread in time")
  ok()
