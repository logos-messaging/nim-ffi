{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net, locks, json, tables]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import ./ffi_types, ./ffi_thread_request, ./internal/ffi_macro, ./logging

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
  watchdogStopSignal: ThreadSignalPtr
    # fired by destroyFFIContext so the watchdog exits immediately instead of waiting out its sleep
  userData*: pointer
  eventCallback*: pointer
  eventUserdata*: pointer
  running: Atomic[bool] # To control when the threads are running
  registeredRequests: ptr Table[cstring, FFIRequestProc]
    # Pointer to with the registered requests at compile time

const MaxFFIContexts* = 32
  ## Maximum number of concurrently live FFI contexts when using FFIContextPool.
  ## Fds and threads are only consumed for slots that are actually acquired,
  ## so this value only affects the upfront memory of the pool array.

type FFIContextPool*[T] = object
  ## Fixed-size pool of FFI contexts. Avoids dynamic heap allocation per context
  ## and bounds the total number of file descriptors consumed by ThreadSignalPtrs
  ## to at most MaxFFIContexts * 2.
  slots: array[MaxFFIContexts, FFIContext[T]]
  inUse: array[MaxFFIContexts, Atomic[bool]]

const git_version* {.strdefine.} = "n/a"

template callEventCallback*(ctx: ptr FFIContext, eventName: string, body: untyped) =
  if isNil(ctx[].eventCallback):
    chronicles.error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[FFICallBack](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[FFICallBack](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
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

    # Give time for the node to be created and up before sending watchdog requests.
    # waitSync returns early if watchdogStopSignal fires (i.e. on destroy).
    let startWait = ctx.watchdogStopSignal.waitSync(WatchdogStartDelay)
    if startWait.isErr():
      error "watchdog: start-delay waitSync failed", err = startWait.error
    elif startWait.get():
      return # stop signal fired during start delay

    while ctx.running.load:
      let intervalWait = ctx.watchdogStopSignal.waitSync(WatchdogTimeinterval)
      if intervalWait.isErr():
        error "watchdog: interval waitSync failed", err = intervalWait.error
      elif intervalWait.get() or not ctx.running.load:
        break

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
    except CatchableError as exc:
      Result[string, string].err(
        "Exception in processRequest for " & reqId & ": " & exc.msg
      )

  ## handleRes may raise (OOM, GC setup) even though it is rare. Catching here
  ## keeps the async proc raises:[] compatible. The defer inside handleRes
  ## guarantees request is freed before the exception propagates.
  try:
    handleRes(res, request)
  except Exception as exc:
    error "Unexpected exception in handleRes", exc = exc.msg

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## FFI thread body that attends library user API requests

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    var ffiReqHandler: T
      ## Holds the main library object, i.e., in charge of handling the ffi requests.
      ## e.g., Waku, LibP2P, SDS, etc.

    while true:
      await ctx.reqSignal.wait()

      if ctx.running.load == false:
        break

      ## Wait for a request from the ffi consumer thread
      var request: ptr FFIThreadRequest
      let recvOk = ctx.reqChannel.tryRecv(request)
      if not recvOk:
        chronicles.error "ffi thread could not receive a request"
        continue

      ctx.myLib = addr ffiReqHandler

      ## Handle the request
      asyncSpawn processRequest(request, ctx)

      let fireRes = ctx.reqReceivedSignal.fireSync()
      if fireRes.isErr():
        error "could not fireSync back to requester thread", error = fireRes.error

  waitFor ffiRun(ctx)

proc closeResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Closes file descriptors and deinits the lock. Does NOT free ctx memory.
  ## Used by initContextResources error paths and pool destroy, where ctx is
  ## not heap-allocated (pool slots live in a fixed array, not on the heap).
  ctx.lock.deinitLock()
  if not ctx.reqSignal.isNil():
    ?ctx.reqSignal.close()
  if not ctx.reqReceivedSignal.isNil():
    ?ctx.reqReceivedSignal.close()
  if not ctx.watchdogStopSignal.isNil():
    ?ctx.watchdogStopSignal.close()
  return ok()

proc cleanUpResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Full cleanup for heap-allocated contexts: closes all resources and frees memory.
  defer:
    freeShared(ctx)
  return ctx.closeResources()

proc initContextResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Initialises all resources inside an already-allocated FFIContext slot.
  ## On failure every partially-initialised resource is closed; the caller
  ## is responsible for releasing the slot (freeShared or pool.releaseSlot).
  ctx.lock.initLock()

  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    ctx.closeResources().isOkOr:
      return err("could not close resources after reqSignal failure: " & $error)
    return err("couldn't create reqSignal ThreadSignalPtr: " & $error)

  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    ctx.closeResources().isOkOr:
      return err("could not close resources after reqReceivedSignal failure: " & $error)
    return err("couldn't create reqReceivedSignal ThreadSignalPtr")

  ctx.watchdogStopSignal = ThreadSignalPtr.new().valueOr:
    ctx.closeResources().isOkOr:
      return
        err("could not close resources after watchdogStopSignal failure: " & $error)
    return err("couldn't create watchdogStopSignal ThreadSignalPtr")

  ctx.registeredRequests = addr ffi_types.registeredRequests

  ctx.running.store(true)

  try:
    createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    ctx.closeResources().isOkOr:
      error "failed to close resources after ffiThread creation failure", err = error
    return err("failed to create the FFI thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.watchdogThread, watchdogThreadBody, ctx)
  except ValueError, ResourceExhaustedError:
    ctx.running.store(false)
    let fireRes = ctx.reqSignal.fireSync()
    if fireRes.isErr():
      error "failed to signal ffiThread during watchdog cleanup", err = fireRes.error
    joinThread(ctx.ffiThread)
    ctx.closeResources().isOkOr:
      error "failed to close resources after watchdogThread creation failure",
        err = error
    return err("failed to create the watchdog thread: " & getCurrentExceptionMsg())

  return ok()

# ── Pool helpers ─────────────────────────────────────────────────────────────

proc acquireSlot[T](pool: var FFIContextPool[T]): Result[ptr FFIContext[T], string] =
  for i in 0 ..< MaxFFIContexts:
    var expected = false
    if pool.inUse[i].compareExchange(expected, true):
      return ok(pool.slots[i].addr)
  return err("FFI context pool exhausted (max " & $MaxFFIContexts & " contexts)")

proc releaseSlot[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]) =
  for i in 0 ..< MaxFFIContexts:
    if pool.slots[i].addr == ctx:
      pool.inUse[i].store(false)
      return

# ── Public API ────────────────────────────────────────────────────────────────

proc createFFIContext*[T](): Result[ptr FFIContext[T], string] =
  ## Creates a heap-allocated FFI context. The caller must call destroyFFIContext(ctx)
  ## to release it. Prefer the pool overload when the maximum context count is known.
  var ctx = createShared(FFIContext[T], 1)
  initContextResources(ctx).isOkOr:
    freeShared(ctx)
    return err(error)
  return ok(ctx)

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a slot from the fixed pool and initialises it as an FFI context.
  ## Bounded fd usage: at most MaxFFIContexts * 2 ThreadSignalPtr fds are ever open.
  let ctx = pool.acquireSlot().valueOr:
    return err(error)
  initContextResources(ctx).isOkOr:
    pool.releaseSlot(ctx)
    return err(error)
  return ok(ctx)

proc signalStop[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ctx.running.store(false)
  let ffiSignaled = ctx.reqSignal.fireSync().valueOr:
    ctx.onNotResponding()
    return err("error signaling reqSignal in destroyFFIContext: " & $error)
  if not ffiSignaled:
    ctx.onNotResponding()
    return err("failed to signal reqSignal on time in destroyFFIContext")
  let wdSignaled = ctx.watchdogStopSignal.fireSync().valueOr:
    return err("error signaling watchdogStopSignal in destroyFFIContext: " & $error)
  if not wdSignaled:
    return err("failed to signal watchdogStopSignal on time in destroyFFIContext")
  return ok()

proc destroyFFIContext*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  defer:
    joinThread(ctx.ffiThread)
    joinThread(ctx.watchdogThread)
    ctx.cleanUpResources().isOkOr:
      error "failed to clean up resources in destroyFFIContext", err = error
  return ctx.signalStop()

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Stops the FFI context and returns its slot to the pool.
  defer:
    joinThread(ctx.ffiThread)
    joinThread(ctx.watchdogThread)
    ctx.closeResources().isOkOr:
      error "failed to close resources in destroyFFIContext", err = error
    pool.releaseSlot(ctx)
  return ctx.signalStop()

template checkParams*(ctx: ptr FFIContext, callback: FFICallBack, userData: pointer) =
  if not isNil(ctx):
    ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK
