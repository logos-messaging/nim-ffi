{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[atomics, locks, json, tables, sequtils]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import ./ffi_types, ./ffi_thread_request, ./internal/ffi_macro, ./logging

type FFICallbackState* = object
  ## Holds the C event callback and its associated user-data pointer.
  ## Embedded in FFIContext and referenced from the FFI thread via a thread-local.
  callback*: pointer
  userData*: pointer

type CtxLifecycle {.pure.} = enum
  ## Request-acceptance + recycle handshake for a pooled context, held as an
  ## Atomic on FFIContext. ("Recycle" = drain the context and return its context to
  ## the pool for reuse, keeping the worker alive — unlike destroyFFIContext, which
  ## fully tears the threads down.) Invariants:
  ##   * Requests are accepted ONLY in `Active`; the gate in sendRequestToFFIThread
  ##     and the watchdog ping both test `== Active`.
  ##   * Legal transitions, and who performs them:
  ##       Active         -> RecyclePending   requestRecycle (caller, under `lock`)
  ##       RecyclePending -> Recycling        the FFI loop   (one-shot compareExchange)
  ##       Recycling      -> Active           markReacquired (caller, on reuse)
  ##     (initContextResources starts a context in `Active`.)
  ##   * The gate stays closed across BOTH RecyclePending and Recycling, so no
  ##     request can dispatch onto a context being recycled or about to be reused.
  ##   * Only the FFI loop makes the RecyclePending -> Recycling move, so the
  ##     recycle runs exactly once per request.
  Active            ## serving requests
  RecyclePending    ## recycle requested; FFI loop hasn't claimed it yet
  Recycling         ## FFI loop claimed it: draining handlers, then freeing

type FFIContext*[T] = object
  myLib*: ptr T
    # main library object (e.g., Waku, LibP2P, SDS,  the one to be exposed as a library)
  ffiThread: Thread[(ptr FFIContext[T])]
    # represents the main FFI thread in charge of attending API consumer actions
  watchdogThread: Thread[(ptr FFIContext[T])]
    # monitors the FFI thread and notifies the FFI API consumer if it hangs
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr FFIThreadRequest]
  reqSignal: ThreadSignalPtr # to notify the FFI Thread that a new request is sent
  reqReceivedSignal: ThreadSignalPtr
    # to signal main thread, interfacing with the FFI thread, that FFI thread received the request
  stopSignal: ThreadSignalPtr
    # fired by destroyFFIContext so both ffiThread and watchdogThread can exit promptly
  threadExitSignal: ThreadSignalPtr
    # fired by ffiThread just before it exits; destroyFFIContext waits on
    # this with a bounded timeout instead of joining unconditionally, so a
    # blocked event loop cannot hang the caller forever
  userData*: pointer
  callbackState*: FFICallbackState
  running: Atomic[bool] # To control when the threads are running
  lifecycle: Atomic[CtxLifecycle]
    # Request gate + recycle handshake in one. See CtxLifecycle for the states,
    # transitions and invariants.
  recycleCallback: FFICallBack
    # The destructor's callback, fired by the recycle handler with the outcome:
    # RET_OK once drained, RET_ERR if it timed out. Set by requestRecycle.
  recycleUserData: pointer
  inUse: Atomic[bool]
    # Whether the context is claimed. createFFIContext claims it (false -> true); the
    # recycle handler clears it once drained. On the context so the owning thread can
    # release it without reaching into the pool.
  registeredRequests: ptr Table[cstring, FFIRequestProc]
    # Pointer to with the registered requests at compile time

var ffiCurrentCallbackState* {.threadvar.}: ptr FFICallbackState
  ## Set by ffiThreadBody at thread startup; read by dispatchFfiEvent.

const git_version* {.strdefine.} = "n/a"

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
  # This lock is only necessary while we use a SP Channel and while the signalling
  # between threads assumes that there aren't concurrent requests.
  # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
  # requests concurrently and spare us the need of locks
  defer:
    ctx.lock.release()

  ## A recycle closes this gate (under the same lock), so a queued or late sender
  ## bails here instead of dispatching onto a context about to be reused.
  if ctx.lifecycle.load() != CtxLifecycle.Active:
    deleteRequest(ffiRequest)
    return err("FFI context is not accepting requests (being recycled)")

  ## Sending the request
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
    ## Do not free ffiRequest here: the FFI thread was already signaled and
    ## will process (and free) it.
    return err("Couldn't receive reqReceivedSignal signal")

  ## Notice that in case of "ok", the deallocShared(req) is performed by the FFI Thread in the
  ## process proc.
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
        ## Gate closed (being recycled, not yet reused): a ping would just fail
        ## and spuriously trip onNotResponding. Skip until reused.
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
  ## ffiThreadBody keeps this proc's Future in the run loop's `pending` seq so a
  ## destroy can await (or cancel) it before freeing myLib.

  let reqId = $request[].reqId
    ## The reqId determines which proc will handle the request.
    ## The registeredRequests represents a table defined at compile time.
    ## Then, registeredRequests == Table[reqId, proc-handling-the-request-asynchronously]

  ## Explicit conversion keeps `reqId` alive as the backing string,
  ## avoiding the implicit string→cstring warning that will become an error.
  let reqIdCs = reqId.cstring

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
      ## Destroy timed out and cancelled us: turn it into an error so handleRes
      ## still fires the callback and frees the request.
      Result[string, string].err("Request cancelled during destroy: " & exc.msg)
    except AsyncError as exc:
      Result[string, string].err(
        "Async error in processRequest for " & reqId & ": " & exc.msg
      )

  ## handleRes may raise (OOM, GC setup) even though it is rare. Catching here
  ## keeps the async proc raises:[] compatible. The defer inside handleRes
  ## guarantees request is freed before the exception propagates.
  try:
    handleRes(res, request)
  except Exception as exc:
    error "Unexpected exception in handleRes", error = exc.msg

proc freeLib[T](ctx: ptr FFIContext[T]) {.gcsafe.} =
  ## Frees the createShared'd library object in ctx.myLib. Runs on the FFI
  ## thread, which is what makes destroying its GC fields safe.
  if ctx.myLib.isNil():
    return
  when not defined(gcRefc):
    ## orc: shared heap, so run the destructor here. The hook isn't inferred
    ## gcsafe but only touches this (owning-thread) object, so assert it.
    {.cast(gcsafe).}:
      `=destroy`(ctx.myLib[])
  else:
    ## refc: `=destroy` here hits the unsafe Selector path (see cleanUpResources).
    ## Reclaim only the wrapper; leak the inner fields, like the signal fds.
    discard
  freeShared(ctx.myLib)
  ctx.myLib = nil

var RecycleTimeout* = 1500.milliseconds
  ## Upper bound the recycle handler waits for in-flight handlers before it
  ## cancels them and reports the ctx as stuck. The drain returns as soon as they
  ## finish, so this only bounds a *stuck* handler. A `var` so tests can shorten it.

proc recycleContext[T](
    ctx: ptr FFIContext[T], pending: ptr seq[Future[void]]
) {.async.} =
  ## Recycle handler, on the FFI thread (requestRecycle already closed the gate):
  ## drain the in-flight handlers, free the lib object, release the context for reuse,
  ## and fire the callback with the outcome. Never blocks the caller.
  ##
  ## `pending` is the run loop's seq of handler Futures, by ptr (async procs can't
  ## take `var`); holding the instances lets us await and cancel them.
  pending[].keepItIf(not it.finished())

  ## 1. Let the in-flight handlers finish on their own, bounded by RecycleTimeout.
  var naturallyDrained = pending[].len == 0
  if not naturallyDrained:
    naturallyDrained = await allFutures(pending[]).withTimeout(RecycleTimeout)

  ## 2. If any are wedged, cancel them and give the cancellations a bounded moment
  ##    to unwind, so the context can be reclaimed rather than leaked.
  var safeToRecycle = naturallyDrained
  if not naturallyDrained:
    for fut in pending[]:
      if not fut.finished():
        fut.cancelSoon()
    safeToRecycle = await allFutures(pending[]).withTimeout(RecycleTimeout)

  let cb = ctx.recycleCallback
  let ud = ctx.recycleUserData
  ctx.recycleCallback = nil

  if safeToRecycle:
    ## Nothing can touch the context now. Free the lib here, then release the context
    ## BEFORE the callback (the atomic store publishes these writes to whoever
    ## reclaims it) so a caller reacquiring on the callback finds it already free.
    freeLib(ctx)
    ctx.callbackState = default(FFICallbackState)
    pending[].setLen(0)
    ctx.unclaim()

  if not cb.isNil():
    foreignThreadGc:
      ## Never hand the callback nil: empty string on success, reason on timeout.
      ## An empty string's cstring still points at a '\0', so msg[0] is a safe
      ## address with len 0.
      let msg =
        if naturallyDrained: ""
        else: "recycle: in-flight requests did not finish in time"
      let cmsg = msg.cstring
      let retCode = if naturallyDrained: RET_OK else: RET_ERR
      cb(retCode, unsafeAddr cmsg[0], cast[csize_t](msg.len), ud)

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## FFI thread body that attends library user API requests
  ffiCurrentCallbackState = addr ctx[].callbackState

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  defer:
    # Signal destroyFFIContext that this thread has exited, so its bounded
    # wait can unblock and proceed with cleanup.
    let fireRes = ctx.threadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire threadExitSignal on FFI thread exit", err = fireRes.error

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    ## Handler Futures live here on the FFI thread's heap, NOT on FFIContext
    ## (shared pool memory, must stay GC-free); holding them lets destroy await
    ## and cancel them.
    var pending: seq[Future[void]]

    while ctx.running.load():
      ## Recycle requested: claim it (RecyclePending -> Recycling, one-shot) and run
      ## the recycle on this owning thread, then keep looping so the worker stays
      ## alive for the context's next reuse.
      var expected = CtxLifecycle.RecyclePending
      if ctx.lifecycle.compareExchange(expected, CtxLifecycle.Recycling):
        await recycleContext(ctx, addr pending)
        continue

      let gotSignal = await ctx.reqSignal.wait().withTimeout(100.milliseconds)
      if not gotSignal:
        continue

      ## Wait for a request from the ffi consumer thread
      var request: ptr FFIThreadRequest
      if not ctx.reqChannel.tryRecv(request):
        continue

      ## Dispatch and remember the handler's Future (pruning finished ones) so a
      ## later recycle can await or cancel it.
      pending.keepItIf(not it.finished())
      pending.add(processRequest(request, ctx))

      let fireRes = ctx.reqReceivedSignal.fireSync()
      if fireRes.isErr():
        error "could not fireSync back to requester thread", error = fireRes.error

  waitFor ffiRun(ctx)

proc cleanUpResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Full cleanup for heap-allocated contexts: closes all resources and frees memory.
  defer:
    freeShared(ctx)
  ctx.lock.deinitLock()
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
    if not ctx.reqReceivedSignal.isNil():
      ?ctx.reqReceivedSignal.close()
    if not ctx.stopSignal.isNil():
      ?ctx.stopSignal.close()
    if not ctx.threadExitSignal.isNil():
      ?ctx.threadExitSignal.close()
  return ok()

proc initContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Initialises all resources inside an already-allocated FFIContext.
  ## On failure every partially-initialised resource is closed; the caller
  ## is responsible for releasing the context (freeShared or ctx.unclaim()).
  ctx.lock.initLock()

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

  ctx.registeredRequests = addr ffi_types.registeredRequests

  ctx.lifecycle.store(CtxLifecycle.Active)
  ctx.running.store(true)

  try:
    createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    return err("failed to create the FFI thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.watchdogThread, watchdogThreadBody, ctx)
  except ValueError, ResourceExhaustedError:
    ## ffiThread is already running; signal it to exit and join before the
    ## deferred cleanUpResources closes the signals it's waiting on.
    ctx.running.store(false)
    let fireRes = ctx.reqSignal.fireSync()
    if fireRes.isErr():
      error "failed to signal ffiThread during watchdog cleanup", error = fireRes.error
    joinThread(ctx.ffiThread)
    return err("failed to create the watchdog thread: " & getCurrentExceptionMsg())

  success = true
  return ok()

proc signalStop*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ctx.running.store(false)
  let reqSignaled = ctx.reqSignal.fireSync().valueOr:
    ctx.onNotResponding()
    return err("error signaling reqSignal in signalStop: " & $error)
  if not reqSignaled:
    ctx.onNotResponding()
    return err("failed to signal reqSignal on time in signalStop")
  let stopSignaled = ctx.stopSignal.fireSync().valueOr:
    return err("error signaling stopSignal in signalStop: " & $error)
  if not stopSignaled:
    return err("failed to signal stopSignal on time in signalStop")
  return ok()

## If the FFI thread's event loop is blocked by a synchronous handler
## (e.g. blocking I/O), it cannot process reqSignal in time to exit.
## stopAndJoinThreads waits on threadExitSignal up to this bound; on timeout it
## returns err and skips joinThread/cleanup (leaking the thread + ctx)
## rather than hanging the caller forever.
const ThreadExitTimeout* = 1500.milliseconds

proc stopAndJoinThreads*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Signals the FFI and watchdog threads to stop, waits up to ThreadExitTimeout
  ## for the FFI thread to exit, and joins both. On timeout returns err and
  ## skips joinThread (leaving the threads live) rather than hanging the caller.
  ## Resource cleanup (signal fds, lock) is the caller's responsibility.
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  let exitedOnTime = ctx.threadExitSignal.waitSync(ThreadExitTimeout).valueOr:
    ctx.onNotResponding()
    return err("error waiting for FFI thread exit: " & $error)

  if not exitedOnTime:
    ctx.onNotResponding()
    return err("FFI thread did not exit in time; leaking ctx to avoid hang")

  joinThread(ctx.ffiThread)
  joinThread(ctx.watchdogThread)
  return ok()

proc requestRecycle*[T](
    ctx: ptr FFIContext[T], callback: FFICallBack, userData: pointer
): Result[void, string] =
  ## Starts ctx recycle process without stopping its worker, so the next
  ## createFFIContext reuses the same threads and fds. 
  ##
  ## During recycling, the FFI thread drains the handlers, frees the lib and releases
  ## the context, then fires `callback` (RET_OK drained, RET_ERR stuck).
  ctx.recycleCallback = callback
  ctx.recycleUserData = userData

  ctx.lock.acquire()
  ctx.lifecycle.store(CtxLifecycle.RecyclePending)
  ctx.lock.release()

  let fired = ctx.reqSignal.fireSync().valueOr:
    return err("requestRecycle: failed to signal the FFI thread: " & $error)
  if not fired:
    return err("requestRecycle: failed to signal the FFI thread in time")
  return ok()

proc markReacquired*[T](ctx: ptr FFIContext[T]) =
  ## Re-arms a recycled context when its context is reacquired by createFFIContext:
  ## moves Recycling -> Active (re-opening the gate). The FFI thread's `pending`
  ## seq was already drained and myLib freed by the recycle handler.
  ctx.lifecycle.store(CtxLifecycle.Active)

proc tryClaim*[T](ctx: ptr FFIContext[T]): bool =
  ## Atomically claim this context (false -> true). Returns true if we won it, false
  ## if it was already claimed. Used by createFFIContext to hand out a free context.
  var expected = false
  ctx.inUse.compareExchange(expected, true)

proc unclaim*[T](ctx: ptr FFIContext[T]) =
  ## Mark the context free for reuse. Called by the recycle handler on the FFI thread
  ## once teardown is done, and on creation failure / full teardown.
  ctx.inUse.store(false)

proc isClaimed*[T](ctx: ptr FFIContext[T]): bool =
  ## Whether the context is currently claimed by a consumer.
  ctx.inUse.load()
