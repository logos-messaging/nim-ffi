{.passc: "-fPIC".}

import system/ansi_c
import std/[atomics, locks, options, tables]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import
  ./ffi_types, ./ffi_events, ./ffi_thread_request, ./internal/ffi_macro, ./logging,
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
  eventQueueSignal: ThreadSignalPtr # wakes the event thread on enqueue
  eventThreadExitSignal: ThreadSignalPtr # mirrors threadExitSignal for the event thread
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  eventQueue*: EventQueue
  ffiHeartbeat*: Atomic[int64] # advanced each FFI-thread loop; event thread reads for liveness
  eventQueueStuck*: Atomic[bool] # sticky overflow flag; recovery is destroy+recreate
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

type NotRespondingEvent* = object

const NotRespondingEventName* = "not_responding"

proc encodeNotRespondingEvent(): seq[byte] =
  EventEnvelope[NotRespondingEvent](
    eventType: NotRespondingEventName, payload: NotRespondingEvent()
  ).cborEncode()

proc dispatchToListeners[T](
    ctx: ptr FFIContext[T], eventName: string, data: pointer, dataLen: int
) =
  ## Holds reg.lock for the entire snapshot + invocation so concurrent
  ## add/remove on this registry blocks until dispatch returns.
  withLock ctx[].eventRegistry.lock:
    let listeners = ctx[].eventRegistry.byEvent.getOrDefault(eventName)
    if listeners.len == 0:
      chronicles.debug "no listener registered", event = eventName
      return
    foreignThreadGc:
      try:
        notifyListenersOk(listeners, data, dataLen)
      except Exception, CatchableError:
        notifyListenersErr(
          listeners,
          "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg(),
        )

proc onNotResponding*(ctx: ptr FFIContext) =
  ## Bypasses the event queue (which may itself be wedged) and dispatches
  ## directly to listeners. Runs on the event thread.
  let event =
    try:
      encodeNotRespondingEvent()
    except CatchableError as exc:
      chronicles.error "onNotResponding - encode failed", err = exc.msg
      return
  let dataPtr: pointer =
    if event.len > 0: unsafeAddr event[0]
    else: nil
  ctx.dispatchToListeners(NotRespondingEventName, dataPtr, event.len)

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
): Result[void, string] =
  # Event-queue overflow refuses further requests; the event thread fires onNotResponding to avoid deadlocking on reg.lock here.
  if ctx.eventQueueStuck.load():
    deleteRequest(ffiRequest)
    return
      err("event queue stuck - library cannot accept new requests")

  # Reentrancy guard: only this thread can fire `reqReceivedSignal`, so a handler dispatching back would self-deadlock.
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
  ok()

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

var ffiEventQueueSignalPtr {.threadvar.}: ThreadSignalPtr
  ## Stashed so the hook below has no closure environment.

proc ffiNotifyEventEnqueuedHook() {.gcsafe, raises: [].} =
  if not ffiEventQueueSignalPtr.isNil():
    let res = ffiEventQueueSignalPtr.fireSync()
    if res.isErr():
      error "failed to fire eventQueueSignal after enqueue", err = res.error

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## FFI thread body that attends library user API requests
  ffiCurrentEventRegistry = addr ctx[].eventRegistry
  ffiCurrentEventQueue = addr ctx[].eventQueue
  ffiCurrentEventQueueStuck = addr ctx[].eventQueueStuck
  ffiEventQueueSignalPtr = ctx.eventQueueSignal
  ffiCurrentNotifyEventEnqueued = ffiNotifyEventEnqueuedHook
  onFFIThread = true

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  defer:
    onFFIThread = false
    # Unblocks destroyFFIContext's bounded wait so cleanup can proceed.
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
      # Freezes if a sync handler blocks the dispatcher; event thread reads to detect wedged FFI thread.
      discard ctx.ffiHeartbeat.fetchAdd(1)

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
        error "draining pending FFI requests on shutdown raised",
          error = exc.msg

  waitFor ffiRun(ctx)

proc freeQueuedEventPayload(qe: QueuedEvent) =
  if not qe.name.isNil:
    c_free(cast[pointer](qe.name))
  if not qe.data.isNil:
    c_free(qe.data)

proc dispatchQueuedEvent[T](ctx: ptr FFIContext[T], qe: QueuedEvent) =
  ## Frees `qe`'s c_malloc buffers on exit.
  defer:
    freeQueuedEventPayload(qe)
  ctx.dispatchToListeners($qe.name, qe.data, qe.dataLen)

proc drainEventQueue[T](ctx: ptr FFIContext[T]) =
  while true:
    let opt = ctx.eventQueue.tryDequeueEvent()
    if opt.isNone:
      break
    ctx.dispatchQueuedEvent(opt.get())

type HeartbeatMonitor = object
  startedAt: Moment
  lastChange: Moment
  lastValue: int64
  notifiedStale: bool

proc initHeartbeatMonitor[T](ctx: ptr FFIContext[T]): HeartbeatMonitor =
  let now = Moment.now()
  HeartbeatMonitor(
    startedAt: now,
    lastChange: now,
    lastValue: ctx.ffiHeartbeat.load(),
    notifiedStale: false,
  )

proc check[T](hb: var HeartbeatMonitor, ctx: ptr FFIContext[T]) =
  ## Fires onNotResponding once the FFI thread's heartbeat counter stops
  ## advancing past the stale threshold. Latches until it moves again.
  if Moment.now() - hb.startedAt <= FFIHeartbeatStartDelay:
    return
  let cur = ctx.ffiHeartbeat.load()
  if cur != hb.lastValue:
    hb.lastValue = cur
    hb.lastChange = Moment.now()
    hb.notifiedStale = false
  elif not hb.notifiedStale and
      Moment.now() - hb.lastChange > FFIHeartbeatStaleThreshold:
    onNotResponding(ctx)
    hb.notifiedStale = true

proc eventRun[T](ctx: ptr FFIContext[T]) {.async.} =
  var hb = initHeartbeatMonitor(ctx)
  var notifiedStuck = false

  while ctx.running.load():
    # Wake on enqueue or tick — whichever first.
    discard await ctx.eventQueueSignal.wait().withTimeout(EventThreadTickInterval)

    ctx.drainEventQueue()

    # Fires here (after drain releases reg.lock) — from the FFI thread it'd deadlock on a back-pressuring listener.
    if not notifiedStuck and ctx.eventQueueStuck.load():
      onNotResponding(ctx)
      notifiedStuck = true

    if not ctx.running.load():
      break
    hb.check(ctx)

proc eventThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## Drains the event queue and runs the FFI-thread heartbeat check.
  ## Owns the queued `c_malloc` payloads until dispatch returns.
  defer:
    let fireRes = ctx.eventThreadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire eventThreadExitSignal", err = fireRes.error

  try:
    waitFor eventRun(ctx)
  except CatchableError as exc:
    error "event thread exited with exception", error = exc.msg

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
  ok()

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
  ctx.eventQueueStuck.store(false)

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
  ok()

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
    error "failed to signal eventQueueSignal in signalStop",
      error = evtSignaled.error
  elif evtSignaled.get() == false:
    error "failed to signal eventQueueSignal on time in signalStop"
  ok()

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
  ok()

proc clearContext[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Stops the FFI context that was created via createFFIContext[T]() (heap).
  ctx.stopAndJoinThreads().isOkOr:
    return err("clearContext: " & $error)
  ctx.cleanUpResources().isOkOr:
    return err("cleanUpResources failed: " & $error)
  ok()
