{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net, locks, json, tables, sets]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import ./ffi_types, ./ffi_thread_request, ./internal/ffi_macro, ./logging

type FFICallbackState* = object
  ## Holds the C event callback and its associated user-data pointer.
  ## Embedded in FFIContext and referenced from the FFI thread via a thread-local.
  callback*: pointer
  userData*: pointer

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
  registeredRequests: ptr Table[cstring, FFIRequestProc]
    # Pointer to with the registered requests at compile time

var ffiCurrentCallbackState* {.threadvar.}: ptr FFICallbackState
  ## Set by ffiThreadBody at thread startup; read by dispatchFfiEvent.

const git_version* {.strdefine.} = "n/a"

var contextRegistry = initHashSet[pointer]()
var contextRegistryLock: Lock
contextRegistryLock.initLock()

proc registerCtx(ctx: pointer) =
  {.cast(gcsafe).}:
    contextRegistryLock.acquire()
    defer: contextRegistryLock.release()
    contextRegistry.incl(ctx)

proc unregisterCtx(ctx: pointer) =
  {.cast(gcsafe).}:
    contextRegistryLock.acquire()
    defer: contextRegistryLock.release()
    contextRegistry.excl(ctx)

proc isValidCtx*(ctx: pointer): bool =
  ## Returns true only if ctx was created by createFFIContext and not yet destroyed.
  ## Rejects nil, offset-invalid, and dangling pointers at the API boundary.
  {.cast(gcsafe).}:
    contextRegistryLock.acquire()
    defer: contextRegistryLock.release()
    return contextRegistry.contains(ctx)

template callEventCallback*(ctx: ptr FFIContext, eventName: string, body: untyped) =
  if isNil(ctx[].callbackState.callback):
    chronicles.error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[FFICallBack](ctx[].callbackState.callback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].callbackState.userData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[FFICallBack](ctx[].callbackState.callback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].callbackState.userData
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
      let msg =
        "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg()
      cast[FFICallBack](ffiState[].callback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ffiState[].userData
      )

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
): Result[void, string] =
  if not isValidCtx(cast[pointer](ctx)):
    deleteRequest(ffiRequest)
    return err("ctx is not a valid FFI context")
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

    # Give time for the node to be created and up before sending watchdog requests
    let initialStop = await ctx.stopSignal.wait().withTimeout(WatchdogStartDelay)
    if initialStop or ctx.running.load == false:
      return

    while true:
      let intervalStop = await ctx.stopSignal.wait().withTimeout(WatchdogTimeinterval)

      if intervalStop or ctx.running.load == false:
        debug "Watchdog thread exiting because FFIContext is not running"
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
    except AsyncError as exc:
      Result[string, string].err("Async error in processRequest for " & reqId & ": " & exc.msg)

  ## handleRes may raise (OOM, GC setup) even though it is rare. Catching here
  ## keeps the async proc raises:[] compatible. The defer inside handleRes
  ## guarantees request is freed before the exception propagates.
  try:
    handleRes(res, request)
  except Exception as exc:
    error "Unexpected exception in handleRes", error = exc.msg

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## FFI thread body that attends library user API requests
  ffiCurrentCallbackState = addr ctx[].callbackState

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  defer:
    # Signal destroyFFIContext that this thread has exited, so its bounded
    # wait can unblock and proceed with cleanup.
    let fireRes = ctx.threadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire threadExitSignal on FFI thread exit",
        err = fireRes.error

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    var ffiReqHandler: T
      ## Holds the main library object, i.e., in charge of handling the ffi requests.
      ## e.g., Waku, LibP2P, SDS, etc.

    while ctx.running.load():
      let gotSignal = await ctx.reqSignal.wait().withTimeout(100.milliseconds)
      if not gotSignal:
        continue

      ## Wait for a request from the ffi consumer thread
      var request: ptr FFIThreadRequest
      if not ctx.reqChannel.tryRecv(request):
        continue

      if ctx.myLib.isNil():
        ctx.myLib = addr ffiReqHandler

      ## Handle the request
      asyncSpawn processRequest(request, ctx)

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

proc initContextResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Initialises all resources inside an already-allocated FFIContext slot.
  ## On failure every partially-initialised resource is closed; the caller
  ## is responsible for releasing the slot (freeShared or pool.releaseSlot).
  ctx.lock.initLock()

  var success = false
  defer:
    if not success:
      ctx.cleanUpResources().isOkOr:
        error "failed to clean up resources after createFFIContext failure",
          err = error

  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr: " & $error)

  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqReceivedSignal ThreadSignalPtr: " & $error)

  ctx.stopSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create stopSignal ThreadSignalPtr: " & $error)

  ctx.threadExitSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create threadExitSignal ThreadSignalPtr: " & $error)

  ctx.registeredRequests = addr ffi_types.registeredRequests

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

  registerCtx(cast[pointer](ctx))
  success = true
  return ok()

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

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a slot from the fixed pool and initialises it as an FFI context.
  ## Bounded fd usage: at most MaxFFIContexts * 2 ThreadSignalPtr fds are ever open.
  let ctx = pool.acquireSlot().valueOr:
    return err("createFFIContext: acquireSlot failed: " & $error)
  initContextResources(ctx).isOkOr:
    pool.releaseSlot(ctx)
    return err("createFFIContext: initContextResources failed: " & $error)
  return ok(ctx)

proc signalStop*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ctx.running.store(false)
  let reqSignaled = ctx.reqSignal.fireSync().valueOr:
    ctx.onNotResponding()
    return err("error signaling reqSignal in destroyFFIContext: " & $error)
  if not reqSignaled:
    ctx.onNotResponding()
    return err("failed to signal reqSignal on time in destroyFFIContext")
  let stopSignaled = ctx.stopSignal.fireSync().valueOr:
    return err("error signaling stopSignal in destroyFFIContext: " & $error)
  if not stopSignaled:
    return err("failed to signal stopSignal on time in destroyFFIContext")
  return ok()

## If the FFI thread's event loop is blocked by a synchronous handler
## (e.g. blocking I/O), it cannot process reqSignal in time to exit.
## destroyFFIContext waits on threadExitSignal up to this bound; on timeout it
## returns err and skips joinThread/cleanup (leaking the thread + ctx slot)
## rather than hanging the caller forever.
const ThreadExitTimeout = 1500.milliseconds

proc destroyFFIContext[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Stops the FFI context that was created via createFFIContext[T]() (heap).
  unregisterCtx(cast[pointer](ctx))

  ctx.signalStop().isOkOr:
    return err("destroyFFIContext: signalStop failed: " & $error)

  let exitedOnTime = ctx.threadExitSignal.waitSync(ThreadExitTimeout).valueOr:
    ctx.onNotResponding()
    return err("error waiting for FFI thread exit: " & $error)

  if not exitedOnTime:
    ctx.onNotResponding()
    return err("FFI thread did not exit in time; leaking ctx to avoid hang")

  joinThread(ctx.ffiThread)
  joinThread(ctx.watchdogThread)
  ctx.cleanUpResources().isOkOr:
    return err("cleanUpResources failed: " & $error)
  return ok()

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Stops the FFI context and returns its slot to the pool. If the FFI thread
  ## is blocked and does not exit in time, the slot is leaked rather than
  ## reclaimed — closing its resources while the thread is still live would be
  ## unsafe.
  unregisterCtx(cast[pointer](ctx))

  ctx.signalStop().isOkOr:
    return err("destroyFFIContext(pool): signalStop failed: " & $error)

  let exitedOnTime = ctx.threadExitSignal.waitSync(ThreadExitTimeout).valueOr:
    ctx.onNotResponding()
    return err("error waiting for FFI thread exit: " & $error)

  if not exitedOnTime:
    ctx.onNotResponding()
    return err("FFI thread did not exit in time; leaking pool slot to avoid hang")

  joinThread(ctx.ffiThread)
  joinThread(ctx.watchdogThread)
  pool.releaseSlot(ctx)
  return ok()

template checkParams*(ctx: ptr FFIContext, callback: FFICallBack, userData: pointer) =
  if not isValidCtx(cast[pointer](ctx)):
    return RET_ERR

  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK
