## FFIContext type plus lifecycle (init / signal-stop / join / destroy).
##
## The per-thread bodies live in `ffi_thread.nim` and `event_thread.nim`,
## included below so the thread code can access the private FFIContext
## fields without forcing them through a public surface.

{.passc: "-fPIC".}

import std/[atomics, locks, options, tables, sequtils]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import ./ffi_types, ./ffi_thread_request, ./internal/ffi_macro, ./logging

type FFICallbackState* = object
  ## Holds the C event callback and its associated user-data pointer.
  ## Embedded in FFIContext and referenced from the FFI thread via a thread-local.
  callback*: pointer
  userData*: pointer

type CtxLifecycle {.pure.} = enum
  ## State machine guarding a pooled FFI context, held as an Atomic on FFIContext.
  ## Transitions:
  ##   Active         -> RecyclePending   when ffiDtor is invoked
  ##   RecyclePending -> Recycling        The process completed the in-flight processes and is ready for lib cleanup and release
  ##   Recycling      -> Active           When the FFI thread is ready again to attend to requests
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
  lifecycle: Atomic[CtxLifecycle]
  recycleCallback: FFICallBack
    # The destructor's callback, fired by the recycle handler with the outcome:
    # RET_OK once drained, RET_ERR if it timed out. Set by requestRecycle.
  recycleUserData: pointer
  inUse: Atomic[bool]
    # Whether the context is claimed. createFFIContext claims it (false -> true); the
    # recycle handler clears it once drained. On the context so the owning thread can
    # release it without reaching into the pool.
  registeredRequests: ptr Table[cstring, FFIRequestProc]

var onFFIThread* {.threadvar.}: bool
  # Re-entrant dispatch guard for `sendRequestToFFIThread`.

const git_version* {.strdefine.} = "n/a"

const
  EventThreadTickInterval* = 1.seconds
  FFIHeartbeatStartDelay* = 10.seconds # grace window for library startup
  FFIHeartbeatStaleThreshold* = 1.seconds

include ./event_thread
include ./ffi_thread

template closeAndNil(field: untyped) =
  if not field.isNil():
    ?field.close()
    field = nil

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`. Threads MUST be joined first;
  ## fields are nil'd after close so re-init on the same slot is safe.
template callEventCallback*(ctx: ptr FFIContext, eventName: string, body: untyped) =
  if isNil(ctx[].callbackState.callback):
    chronicles.error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[FFICallBack](ctx[].callbackState.callback)(
        RET_OK,
        unsafeAddr event[0],
        cast[csize_t](len(event)),
        ctx[].callbackState.userData,
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[FFICallBack](ctx[].callbackState.callback)(
        RET_ERR,
        unsafeAddr msg[0],
        cast[csize_t](len(msg)),
        ctx[].callbackState.userData,
      )

template dispatchFfiEvent*(eventName: string, body: untyped) =
  ## Dispatches an FFI event to the callback registered via `{libName}_set_event_callback`.
  ## `body` is evaluated lazily — only when a callback is registered.
  ## Valid only on the FFI thread (i.e., inside {.ffi.} proc bodies and their async closures).
  let ffiState = ffiCurrentCallbackState
  if isNil(ffiState) or isNil(ffiState[].callback):
    chronicles.error eventName & " - event callback not set"
    return
  foreignThreadGc:
    try:
      let event = body
      cast[FFICallBack](ffiState[].callback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ffiState[].userData
      )
    except Exception, CatchableError:
      let msg = "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg()
      cast[FFICallBack](ffiState[].callback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ffiState[].userData
      )

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
): Result[void, string] =
  ctx.lock.acquire()
  defer:
    ctx.lock.release()

  if ctx.lifecycle.load() != CtxLifecycle.Active:
    deleteRequest(ffiRequest)
    return err("FFI context is not accepting requests (being recycled)")

  ## Sending the request to the FFI thread
  let sentOk = ctx.reqChannel.trySend(ffiRequest)
  if not sentOk:
    deleteRequest(ffiRequest)
    return err("Couldn't send a request to the ffi thread")

  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    deleteRequest(ffiRequest)
    return err("failed fireSync: " & $fireSyncRes.error)

  if fireSyncRes.get() == false:
    deleteRequest(ffiRequest)
    return err("Couldn't fireSync in time")

  ## wait until the FFI working thread properly received the request
  let res = ctx.reqReceivedSignal.waitSync(timeout)
  if res.isErr():
    return err("Couldn't receive reqReceivedSignal signal")

  return ok()

type Foo = object
registerReqFFI(WatchdogReq, foo: ptr Foo):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("FFI thread is not blocked")

type JsonNotRespondingEvent = object
  eventType: string

proc init(T: type JsonNotRespondingEvent): T =
  return JsonNotRespondingEvent(eventType: "not_responding")

proc `$`(event: JsonNotRespondingEvent): string =
  $(%*event)

proc onNotResponding*(ctx: ptr FFIContext) =
  callEventCallback(ctx, "onNotResponding"):
    $JsonNotRespondingEvent.init()

proc watchdogThreadBody(ctx: ptr FFIContext) {.thread.} =
  ## Watchdog thread that monitors the FFI thread and notifies the library user if it hangs.
  ## This thread never blocks.

  let watchdogRun = proc(ctx: ptr FFIContext) {.async.} =
    const WatchdogStartDelay = 10.seconds
    const WatchdogTimeinterval = 1.seconds
    const WatchdogTimeout = 20.seconds

    # Give time for the node to be created and up before sending watchdog requests
    let initialStop = await ctx.stopSignal.wait().withTimeout(WatchdogStartDelay)
    if initialStop or ctx.running.load == false:
      return

    while true:
      let intervalStop = await ctx.stopSignal.wait().withTimeout(WatchdogTimeinterval)

      if intervalStop or ctx.running.load == false:
        debug "Watchdog thread exiting because FFIContext is not running"
        break

      if ctx.lifecycle.load() != CtxLifecycle.Active:
        continue

      let callback = proc(
          callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
      ) {.cdecl, gcsafe, raises: [].} =
        discard ## Don't do anything. Just respecting the callback signature.
      const nilUserData = nil

      trace "Sending watchdog request to FFI thread"

      try:
        sendRequestToFFIThread(
          ctx, WatchdogReq.ffiNewReq(callback, nilUserData), WatchdogTimeout
        ).isOkOr:
          error "Failed to send watchdog request to FFI thread", error = $error
          onNotResponding(ctx)
      except Exception as exc:
        error "Exception sending watchdog request", exc = exc.msg
        onNotResponding(ctx)

  waitFor watchdogRun(ctx)

proc processRequest[T](
    request: ptr FFIThreadRequest, ctx: ptr FFIContext[T]
) {.async.} =
  ## Invoked within the FFI thread to process a request coming from the FFI API consumer thread.

  let reqId = $request[].reqId
    ## The reqId determines which proc will handle the request.
    ## The registeredRequests represents a table defined at compile time.
    ## Then, registeredRequests == Table[reqId, proc-handling-the-request-asynchronously]

  let reqIdCs = reqId.cstring
    # keep `reqId` alive and avoid the implicit string→cstring warning.

  let retFut =
    if not ctx[].registeredRequests[].contains(reqIdCs):
      ## That shouldn't happen because only registered requests should be sent to the FFI thread.
      nilProcess(request[].reqId)
    else:
      ctx[].registeredRequests[][reqIdCs](request[].reqContent, ctx)

  let res =
    try:
      await retFut
    except CancelledError as exc:
      Result[string, string].err("Request cancelled during destroy: " & exc.msg)
    except AsyncError as exc:
      Result[string, string].err(
        "Async error in processRequest for " & reqId & ": " & exc.msg
      )

  ## handleRes may raise (OOM, GC setup) even though it is rare.
  try:
    handleRes(res, request)
  except Exception as exc:
    error "Unexpected exception in handleRes", error = exc.msg

proc freeLib[T](ctx: ptr FFIContext[T]) {.gcsafe.} =
  if ctx.myLib.isNil():
    return

  when not defined(gcRefc):
    {.cast(gcsafe).}:
      `=destroy`(ctx.myLib[])
  else:
    discard
  freeShared(ctx.myLib)
  ctx.myLib = nil

var RecycleTimeout* = 1500.milliseconds
  ## Upper bound the recycle handler waits for in-flight handlers before it
  ## cancels them and reports the ctx as stuck. The drain returns as soon as they
  ## finish, so this only bounds a *stuck* handler. A `var` so tests can shorten it.

proc recycleContext[T](
    ctx: ptr FFIContext[T], ongoingProcessReq: ptr seq[Future[void]]
) {.async.} =
  ## Drain the in-flight handlers, free the lib object, release the context for reuse,
  ## and fire the callback with the outcome. Never blocks the caller.

  ongoingProcessReq[].keepItIf(not it.finished())

  ## 1. Let the in-flight handlers finish on their own, bounded by RecycleTimeout.
  var naturallyDrained = ongoingProcessReq[].len == 0
  if not naturallyDrained:
    naturallyDrained = await allFutures(ongoingProcessReq[]).withTimeout(RecycleTimeout)

  ## 2. If any are wedged, cancel them and give the cancellations a bounded moment
  ##    to unwind, so the context can be reclaimed rather than leaked.
  var safeToRecycle = naturallyDrained
  if not naturallyDrained:
    for fut in ongoingProcessReq[]:
      if not fut.finished():
        fut.cancelSoon()
    safeToRecycle = await allFutures(ongoingProcessReq[]).withTimeout(RecycleTimeout)

  let cb = ctx.recycleCallback
  let ud = ctx.recycleUserData
  ctx.recycleCallback = nil

  if safeToRecycle:
    freeLib(ctx)
    ctx.callbackState = default(FFICallbackState)
    ongoingProcessReq[].setLen(0)
    ctx.release()

  if not cb.isNil():
    foreignThreadGc:
      let msg =
        if naturallyDrained:
          ""
        else:
          "recycle: in-flight requests did not finish in time"
      let cmsg = msg.cstring
      let retCode = if naturallyDrained: RET_OK else: RET_ERR
      cb(retCode, unsafeAddr cmsg[0], cast[csize_t](msg.len), ud)

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## FFI thread body that attends library user API requests
  ffiCurrentCallbackState = addr ctx[].callbackState

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  defer:
    let fireRes = ctx.threadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire threadExitSignal on FFI thread exit", err = fireRes.error

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =

    var ongoingProcessReq: seq[Future[void]]

    while ctx.running.load():
      var expected = CtxLifecycle.RecyclePending
      if ctx.lifecycle.compareExchange(expected, CtxLifecycle.Recycling):
        await recycleContext(ctx, addr ongoingProcessReq)
        continue

      let gotSignal = await ctx.reqSignal.wait().withTimeout(100.milliseconds)
      if not gotSignal:
        continue

      ## Wait for a request from the ffi consumer thread
      var request: ptr FFIThreadRequest
      if not ctx.reqChannel.tryRecv(request):
        continue

      ongoingProcessReq.keepItIf(not it.finished())
      ongoingProcessReq.add(processRequest(request, ctx))

      let fireRes = ctx.reqReceivedSignal.fireSync()
      if fireRes.isErr():
        error "could not fireSync back to requester thread", error = fireRes.error

  waitFor ffiRun(ctx)

proc cleanUpResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Full cleanup for heap-allocated contexts: closes all resources and frees memory.
  defer:
    freeShared(ctx)
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

## Bound on how long clearContext waits for the FFI thread to exit before
## leaking ctx rather than hanging the caller.
const ThreadExitTimeout* = 1500.milliseconds

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

proc requestRecycle*[T](
    ctx: ptr FFIContext[T], callback: FFICallBack, userData: pointer
): Result[void, string] =
  ## Starts ctx recycle process without stopping its worker, so the next
  ## createFFIContext reuses the same threads and fds. 
  ##
  ## During recycling, the FFI thread drains the handlers, frees the lib and releases
  ## the context, then fires `callback` (RET_OK drained, RET_ERR stuck).

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
  return ok()

proc markAsActive*[T](ctx: ptr FFIContext[T]) =
  ctx.lifecycle.store(CtxLifecycle.Active)

proc tryClaim*[T](ctx: ptr FFIContext[T]): bool =
  ## Returns true if acquired the contex, false if it was already claimed.
  var expected = false
  ctx.inUse.compareExchange(expected, true)

proc release*[T](ctx: ptr FFIContext[T]) =
  ctx.inUse.store(false)

proc isInUse*[T](ctx: ptr FFIContext[T]): bool =
  ctx.inUse.load()
