{.passc: "-fPIC".}

import std/[atomics, locks, json, tables]
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
  eventRegistry*: FFIEventRegistry
  running: Atomic[bool] # To control when the threads are running
  registeredRequests: ptr Table[cstring, FFIRequestProc]
    # Pointer to with the registered requests at compile time

var onFFIThread* {.threadvar.}: bool
  ## True while executing inside `ffiThreadBody`. Used by
  ## `sendRequestToFFIThread` to detect re-entrant dispatch from a handler
  ## (which would self-deadlock on `reqReceivedSignal`).

const git_version* {.strdefine.} = "n/a"

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
): Result[void, string] =
  # Reentrancy guard (PR #23 review, item 6): if a handler running on the FFI
  # thread tries to dispatch back through this proc, it would wait forever on
  # `reqReceivedSignal` — which only this thread can fire — and self-deadlock.
  # Return an error instead so the caller can surface it.
  if onFFIThread:
    deleteRequest(ffiRequest)
    return err(
      "reentrant ffi call: a handler invoked sendRequestToFFIThread on its own context"
    )

  # All async submissions serialise on `ctx.lock` for the full
  # trySend + fireSync + waitSync sequence because `reqChannel` is
  # single-producer and `reqReceivedSignal` is shared across callers.
  # Multi-producer redesign is tracked as PR #23 review item 7.
  ctx.lock.acquire()
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
  ## Shim: still emits the legacy JSON payload through the registry, so
  ## existing foreign consumers see no wire-shape change. A follow-up
  ## PR replaces this with a CBOR `NotRespondingEvent`.
  ## Mirrors the dispatch templates' lock-during-invocation contract
  ## (see `ffi_events.nim`).
  withLock ctx[].eventRegistry.lock:
    let snap = ctx[].eventRegistry.byEvent.getOrDefault("onNotResponding")
    if snap.len == 0:
      chronicles.debug "onNotResponding - no listener registered"
      return
    foreignThreadGc:
      let event = $JsonNotRespondingEvent.init()
      for listener in snap:
        listener.callback(
          RET_OK,
          cast[ptr cchar](unsafeAddr event[0]),
          cast[csize_t](len(event)),
          listener.userData,
        )

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
      ctx[].registeredRequests[][reqIdCs](cast[pointer](request), ctx)

  ## Catch every catchable exception (including CancelledError raised by
  ## the shutdown drain in ffiRun) so handleRes — and its `deleteRequest`
  ## defer — always runs. Otherwise an abandoned in-flight handler would
  ## leak its request envelope, reqId copy, and CBOR payload.
  let res =
    try:
      await retFut
    except CatchableError as exc:
      Result[seq[byte], string].err(
        "Error in processRequest for " & reqId & ": " & exc.msg
      )

  ## handleRes may raise (OOM, GC setup) even though it is rare. Catching here
  ## keeps the async proc raises:[] compatible. The defer inside handleRes
  ## guarantees request is freed before the exception propagates.
  try:
    handleRes(res, request)
  except Exception as exc:
    error "Unexpected exception in handleRes", error = exc.msg

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## FFI thread body that attends library user API requests
  ffiCurrentEventRegistry = addr ctx[].eventRegistry
  onFFIThread = true

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  defer:
    onFFIThread = false
    # Signal destroyFFIContext that this thread has exited, so its bounded
    # wait can unblock and proceed with cleanup.
    let fireRes = ctx.threadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire threadExitSignal on FFI thread exit", err = fireRes.error

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    var ffiReqHandler: T
      ## Holds the main library object, i.e., in charge of handling the ffi requests.
      ## e.g., Waku, LibP2P, SDS, etc.

    ## In-flight processRequest futures. Tracked so they can be drained on
    ## shutdown — otherwise destroying the context while a handler is
    ## awaiting (e.g. sleepAsync) abandons the future and leaks the
    ## request's envelope/reqId/payload allocations.
    var pending: seq[Future[void]] = @[]

    proc reapCompleted() =
      var i = 0
      while i < pending.len:
        if pending[i].finished():
          pending.del(i)
        else:
          inc i

    while ctx.running.load():
      reapCompleted()

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
      pending.add processRequest(request, ctx)

      let fireRes = ctx.reqReceivedSignal.fireSync()
      if fireRes.isErr():
        error "could not fireSync back to requester thread", error = fireRes.error

    ## Drain in-flight handlers so each request's `deleteRequest` runs
    ## before we exit. Without this, abandoning a future mid-await would
    ## leak the request allocations (visible to LSan; previously hidden
    ## because Nim's pool allocator kept the chunks alive in the process).
    reapCompleted()
    if pending.len > 0:
      try:
        await allFutures(pending)
      except CatchableError as exc:
        error "draining pending FFI requests on shutdown raised", error = exc.msg

  waitFor ffiRun(ctx)

proc cleanUpResources[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Full cleanup for heap-allocated contexts: closes all resources and frees memory.
  defer:
    freeShared(ctx)
  ctx.lock.deinitLock()
  deinitEventRegistry(ctx[].eventRegistry)
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
  ## Initialises all resources inside an already-allocated FFIContext slot.
  ## On failure every partially-initialised resource is closed; the caller
  ## is responsible for releasing the slot (freeShared or pool.releaseSlot).
  ctx.lock.initLock()
  initEventRegistry(ctx[].eventRegistry)

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
## clearContext waits on threadExitSignal up to this bound; on timeout it
## returns err and skips joinThread/cleanup (leaking the thread + ctx slot)
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

proc clearContext[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Stops the FFI context that was created via createFFIContext[T]() (heap).
  ctx.stopAndJoinThreads().isOkOr:
    return err("clearContext: " & $error)
  ctx.cleanUpResources().isOkOr:
    return err("cleanUpResources failed: " & $error)
  return ok()
