## FFIContext type plus lifecycle (init / signal-stop / join / destroy).
##
## The per-thread bodies live in `ffi_thread.nim` and `event_thread.nim`,
## included below so the thread code can access the private FFIContext
## fields without forcing them through a public surface.

{.passc: "-fPIC".}

import system/ansi_c
import std/[atomics, locks, options, tables]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import
  ./ffi_types,
  ./ffi_events,
  ./ffi_thread_request,
  ./internal/ffi_macro,
  ./logging,
  ./cbor_serial

export ffi_events

type FFIContext*[T] = object
  myLib*: ptr T
    # main library object (e.g., Waku, LibP2P, SDS,  the one to be exposed as a library)
  ffiThread: Thread[(ptr FFIContext[T])]
    # represents the main FFI thread in charge of attending API consumer actions
  eventThread: Thread[(ptr FFIContext[T])]
    # drains the event queue and runs the FFI-thread heartbeat check
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr FFIThreadRequest]
  reqSignal: ThreadSignalPtr # to notify the FFI Thread that a new request is sent
  reqReceivedSignal: ThreadSignalPtr
    # to signal main thread, interfacing with the FFI thread, that FFI thread received the request
  stopSignal: ThreadSignalPtr
  threadExitSignal: ThreadSignalPtr # bounds destroyFFIContext's wait so a blocked loop cannot hang the caller
  eventQueueSignal: ThreadSignalPtr # wakes the event thread on enqueue (used once dispatch is rewired in PR #69)
  eventThreadExitSignal: ThreadSignalPtr # mirrors threadExitSignal for the event thread
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  eventQueue*: EventQueue
  ffiHeartbeat*: Atomic[int64] # advanced each FFI-thread loop; event thread reads for liveness
  running: Atomic[bool] # To control when the threads are running
  registeredRequests: ptr Table[cstring, FFIRequestProc]
    # Pointer to with the registered requests at compile time

var onFFIThread* {.threadvar.}: bool
  ## True while executing inside `ffiThreadBody`. Used by
  ## `sendRequestToFFIThread` to detect re-entrant dispatch from a handler
  ## (which would self-deadlock on `reqReceivedSignal`).

const git_version* {.strdefine.} = "n/a"

const
  EventThreadTickInterval* = 1.seconds # bounds idle heartbeat check latency
  FFIHeartbeatStartDelay* = 10.seconds # grace window for library startup
  FFIHeartbeatStaleThreshold* = 1.seconds

include ./event_thread
include ./ffi_thread

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`: tears down lock, registry, queue,
  ## and signal fds in place. Threads MUST already be joined. Caller owns
  ## the memory holding `ctx`. Fields are nil'd after close so a re-init
  ## on the same slot doesn't double-close.
  ctx.lock.deinitLock()
  deinitEventRegistry(ctx[].eventRegistry)
  deinitEventQueue(ctx[].eventQueue)
  when defined(gcRefc):
    ## ThreadSignalPtr.close() is intentionally skipped under --mm:refc.
    ##
    ## close() goes through chronos's safeUnregisterAndCloseFd, which calls
    ## getThreadDispatcher() and lazily allocates a new Selector for the
    ## main thread. With refc and a heavy ref-object graph torn down by the
    ## FFI thread (libwaku/libp2p), that allocation traps inside rawNewObj
    ## and the refc signal handler re-enters the same allocator — the
    ## process never returns. Captured stack from a hung process:
    ##   close → safeUnregisterAndCloseFd → getThreadDispatcher →
    ##   newDispatcher → Selector.new → newObj (gc.nim:488) →
    ##   rawNewObj (gc.nim:470) → rawNewObj → _sigtramp → signalHandler →
    ##   newObjNoInit → addNewObjToZCT (infinite re-entry)
    ##
    ## --mm:orc does NOT exhibit this bug; see the
    ## "destroyFFIContext refc workaround" suite in tests/test_ffi_context.nim
    ## (test "destroy after heavy ref-allocation workload returns promptly").
    ## The signal fds (a few per ctx) are reclaimed by the OS at process
    ## exit; destroyFFIContext is called once per process lifetime, so the
    ## leak is bounded.
    discard
  else:
    if not ctx.reqSignal.isNil():
      ?ctx.reqSignal.close()
      ctx.reqSignal = nil
    if not ctx.reqReceivedSignal.isNil():
      ?ctx.reqReceivedSignal.close()
      ctx.reqReceivedSignal = nil
    if not ctx.stopSignal.isNil():
      ?ctx.stopSignal.close()
      ctx.stopSignal = nil
    if not ctx.threadExitSignal.isNil():
      ?ctx.threadExitSignal.close()
      ctx.threadExitSignal = nil
    if not ctx.eventQueueSignal.isNil():
      ?ctx.eventQueueSignal.close()
      ctx.eventQueueSignal = nil
    if not ctx.eventThreadExitSignal.isNil():
      ?ctx.eventThreadExitSignal.close()
      ctx.eventThreadExitSignal = nil
  return ok()

proc cleanUpResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Full cleanup for heap-allocated contexts: closes all resources and frees memory.
  defer:
    freeShared(ctx)
  ctx.deinitContextResources()

proc initContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Initialises all resources inside an already-allocated FFIContext slot.
  ## On failure every partially-initialised resource is closed; the caller
  ## is responsible for releasing the slot (freeShared or pool.releaseSlot).
  # Defensive nil: deferred cleanup must never double-close stale pointers on a reused pool slot.
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

  var success = false
  defer:
    if not success:
      ctx.cleanUpResources().isOkOr:
        error "failed to clean up resources after createFFIContext failure",
          error = error

  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr: " & $error)

  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqReceivedSignal ThreadSignalPtr: " & $error)

  ctx.stopSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create stopSignal ThreadSignalPtr: " & $error)

  ctx.threadExitSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create threadExitSignal ThreadSignalPtr: " & $error)

  ctx.eventQueueSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create eventQueueSignal ThreadSignalPtr: " & $error)

  ctx.eventThreadExitSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create eventThreadExitSignal ThreadSignalPtr: " & $error)

  ctx.registeredRequests = addr ffi_types.registeredRequests

  ctx.running.store(true)

  try:
    createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    return err("failed to create the FFI thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.eventThread, eventThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    ## ffiThread is already running; signal it to exit and join before the
    ## deferred cleanUpResources closes the signals it's waiting on.
    ctx.running.store(false)
    let fireRes = ctx.reqSignal.fireSync()
    if fireRes.isErr():
      error "failed to signal ffiThread during event-thread cleanup",
        error = fireRes.error
    joinThread(ctx.ffiThread)
    return err("failed to create the event thread: " & getCurrentExceptionMsg())

  success = true
  return ok()

proc signalStop*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  # Error paths intentionally skip onNotResponding: a back-pressuring
  # listener may hold reg.lock, and onNotResponding takes it — would
  # amplify the stuck state into a deadlock instead of escaping it.
  ctx.running.store(false)
  let reqSignaled = ctx.reqSignal.fireSync().valueOr:
    return err("error signaling reqSignal in signalStop: " & $error)
  if not reqSignaled:
    return err("failed to signal reqSignal on time in signalStop")
  let stopSignaled = ctx.stopSignal.fireSync().valueOr:
    return err("error signaling stopSignal in signalStop: " & $error)
  if not stopSignaled:
    return err("failed to signal stopSignal on time in signalStop")
  # Non-fatal: event thread will see running==false on the next tick.
  let evtSignaled = ctx.eventQueueSignal.fireSync()
  if evtSignaled.isErr():
    error "failed to signal eventQueueSignal in signalStop", error = evtSignaled.error
  elif evtSignaled.get() == false:
    error "failed to signal eventQueueSignal on time in signalStop"
  return ok()

## If the FFI thread's event loop is blocked by a synchronous handler
## (e.g. blocking I/O), it cannot process reqSignal in time to exit.
## clearContext waits on threadExitSignal up to this bound; on timeout it
## returns err and skips joinThread/cleanup (leaking the thread + ctx slot)
## rather than hanging the caller forever.
const ThreadExitTimeout* = 1500.milliseconds

proc stopAndJoinThreads*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Signals both threads to stop, waits up to ThreadExitTimeout per thread,
  ## and joins them. On timeout returns err and skips remaining joins
  ## (leaving the threads live) rather than hanging the caller. Resource
  ## cleanup is the caller's responsibility.
  ##
  ## Timeout paths skip onNotResponding for the same reason signalStop does.
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  let ffiExitedOnTime = ctx.threadExitSignal.waitSync(ThreadExitTimeout).valueOr:
    return err("error waiting for FFI thread exit: " & $error)

  if not ffiExitedOnTime:
    return err("FFI thread did not exit in time; leaking ctx to avoid hang")

  joinThread(ctx.ffiThread)

  let evtExitedOnTime = ctx.eventThreadExitSignal.waitSync(ThreadExitTimeout).valueOr:
    return err("error waiting for event thread exit: " & $error)

  if not evtExitedOnTime:
    return err("event thread did not exit in time; leaking ctx to avoid hang")

  joinThread(ctx.eventThread)
  return ok()

proc clearContext[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Stops the FFI context that was created via createFFIContext[T]() (heap).
  ctx.stopAndJoinThreads().isOkOr:
    return err("clearContext: " & $error)
  ctx.cleanUpResources().isOkOr:
    return err("cleanUpResources failed: " & $error)
  return ok()
