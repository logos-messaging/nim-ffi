{.passc: "-fPIC".}

import std/[atomics, locks, options, tables]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import ./ffi_types, ./ffi_events, ./ffi_thread_request, ./logging, ./cbor_serial

export ffi_events

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
  eventQueueSignal: ThreadSignalPtr
  eventThreadExitSignal: ThreadSignalPtr
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  eventQueue*: EventQueue
  ffiHeartbeat*: Atomic[int64] # advanced each FFI-thread loop; event thread reads for liveness
  eventQueueStuck*: Atomic[bool] # sticky overflow flag
  running: Atomic[bool]
  registeredRequests: ptr Table[cstring, FFIRequestProc]

var onFFIThread* {.threadvar.}: bool
  # Re-entrant dispatch guard for `sendRequestToFFIThread`.

const git_version* {.strdefine.} = "n/a"

const
  EventThreadTickInterval* = 1.seconds
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
  ## Lock held across the whole fan-out so foreign add/remove blocks
  ## until dispatch returns (UAF-close contract from PR #39).
  withLock ctx[].eventRegistry.lock:
    let listeners = ctx[].eventRegistry.byEvent.getOrDefault(eventName)
    if listeners.len == 0:
      chronicles.debug "no listener registered", event = eventName
      return
    foreignThreadGc:
      try:
        notifyListeners(listeners, RET_OK, data, dataLen)
      except Exception, CatchableError:
        notifyListenersErr(
          listeners,
          "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg(),
        )

proc onNotResponding*(ctx: ptr FFIContext) =
  ## Bypasses the (possibly wedged) event queue; runs on the event thread.
  let event =
    try:
      encodeNotRespondingEvent()
    except CatchableError as e:
      chronicles.error "onNotResponding - encode failed", err = e.msg
      return
  let dataPtr: pointer =
    if event.len > 0: unsafeAddr event[0] else: nil
  ctx.dispatchToListeners(NotRespondingEventName, dataPtr, event.len)

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
): Result[void, string] =
  if ctx.eventQueueStuck.load():
    deleteRequest(ffiRequest)
    return err("event queue stuck - library cannot accept new requests")

  if onFFIThread:
    # Re-entrant dispatch from a handler would self-deadlock on `reqReceivedSignal`.
    deleteRequest(ffiRequest)
    return err(
      "reentrant ffi call: a handler invoked sendRequestToFFIThread on its own context"
    )

  # `reqChannel` is single-producer and `reqReceivedSignal` shared; serialise
  # the full trySend + fireSync + waitSync. PR #23 review item 7 tracks SP→MP.
  ctx.lock.acquire()
  defer:
    ctx.lock.release()

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

  let res = ctx.reqReceivedSignal.waitSync(timeout)
  if res.isErr():
    # FFI thread was already signaled; it owns ffiRequest now.
    return err("Couldn't receive reqReceivedSignal signal")

  ok()

proc processRequest[T](
    request: ptr FFIThreadRequest, ctx: ptr FFIContext[T]
) {.async.} =
  let reqId = $request[].reqId
  # Keep `reqId` alive as backing for the cstring view.
  let reqIdCs = reqId.cstring

  let retFut =
    if not ctx[].registeredRequests[].contains(reqIdCs):
      nilProcess(request[].reqId)
    else:
      ctx[].registeredRequests[][reqIdCs](cast[pointer](request), ctx)

  # Catch all (incl. CancelledError from the shutdown drain) so handleRes —
  # and its `deleteRequest` defer — always runs.
  let res =
    try:
      await retFut
    except CatchableError as e:
      Result[seq[byte], string].err(
        "Error in processRequest for " & reqId & ": " & e.msg
      )

  # handleRes may raise (rare: OOM, GC setup); keep `raises: []`.
  try:
    handleRes(res, request)
  except Exception as e:
    error "Unexpected exception in handleRes", error = e.msg

var ffiEventQueueSignalPtr {.threadvar.}: ThreadSignalPtr
  # Stashed so the hook has no closure env.

proc ffiNotifyEventEnqueuedHook() {.gcsafe, raises: [].} =
  if not ffiEventQueueSignalPtr.isNil():
    let res = ffiEventQueueSignalPtr.fireSync()
    if res.isErr():
      error "failed to fire eventQueueSignal after enqueue", err = res.error

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ffiCurrentEventRegistry = addr ctx[].eventRegistry
  ffiCurrentEventQueue = addr ctx[].eventQueue
  ffiCurrentEventQueueStuck = addr ctx[].eventQueueStuck
  ffiEventQueueSignalPtr = ctx.eventQueueSignal
  ffiCurrentNotifyEventEnqueued = ffiNotifyEventEnqueuedHook
  onFFIThread = true

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  defer:
    onFFIThread = false
    # Unblocks destroyFFIContext's bounded wait.
    let fireRes = ctx.threadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire threadExitSignal on FFI thread exit", err = fireRes.error

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    var ffiReqHandler: T

    # Track in-flight handlers so shutdown can drain them — otherwise
    # abandoned futures leak request envelope/reqId/payload.
    var pending: seq[Future[void]] = @[]

    proc reapCompleted() =
      var i = 0
      while i < pending.len:
        if pending[i].finished():
          pending.del(i)
        else:
          inc i

    while ctx.running.load():
      # Freezes if a sync handler blocks; event thread reads for liveness.
      discard ctx.ffiHeartbeat.fetchAdd(1)

      reapCompleted()

      let gotSignal = await ctx.reqSignal.wait().withTimeout(100.milliseconds)
      if not gotSignal:
        continue

      var request: ptr FFIThreadRequest
      if not ctx.reqChannel.tryRecv(request):
        continue

      if ctx.myLib.isNil():
        ctx.myLib = addr ffiReqHandler

      pending.add processRequest(request, ctx)

      let fireRes = ctx.reqReceivedSignal.fireSync()
      if fireRes.isErr():
        error "could not fireSync back to requester thread", error = fireRes.error

    # Drain in-flight handlers so each request's `deleteRequest` runs.
    reapCompleted()
    if pending.len > 0:
      try:
        await allFutures(pending)
      except CatchableError as e:
        error "draining pending FFI requests on shutdown raised", error = e.msg

  waitFor ffiRun(ctx)

proc dispatchQueuedEvent[T](ctx: ptr FFIContext[T], qe: QueuedEvent) =
  defer:
    freeEventBuffers(qe.name, qe.data)
  ctx.dispatchToListeners($qe.name, qe.data, qe.dataLen)

proc drainEventQueue[T](ctx: ptr FFIContext[T]) =
  while true:
    let opt = ctx.eventQueue.tryDequeueEvent()
    if opt.isNone():
      break
    ctx.dispatchQueuedEvent(opt.get())

type HeartbeatMonitor = object
  startedAt: Moment
  lastChange: Moment
  lastValue: int64
  notifiedStale: bool

proc init(T: type HeartbeatMonitor, ctx: ptr FFIContext): T =
  let now = Moment.now()
  T(
    startedAt: now,
    lastChange: now,
    lastValue: ctx.ffiHeartbeat.load(),
    notifiedStale: false,
  )

proc check[T](hb: var HeartbeatMonitor, ctx: ptr FFIContext[T]) =
  ## Fires onNotResponding once the heartbeat stalls past the threshold;
  ## latches until it moves again.
  if Moment.now() - hb.startedAt <= FFIHeartbeatStartDelay:
    return

  let cur = ctx.ffiHeartbeat.load()
  if cur != hb.lastValue:
    hb.lastValue = cur
    hb.lastChange = Moment.now()
    hb.notifiedStale = false
    return

  if hb.notifiedStale:
    return
  if Moment.now() - hb.lastChange <= FFIHeartbeatStaleThreshold:
    return
  onNotResponding(ctx)
  hb.notifiedStale = true

proc eventRun[T](ctx: ptr FFIContext[T]) {.async.} =
  var hb = HeartbeatMonitor.init(ctx)
  var notifiedStuck = false

  while ctx.running.load():
    # Wake on enqueue or tick — whichever first.
    discard await ctx.eventQueueSignal.wait().withTimeout(EventThreadTickInterval)

    ctx.drainEventQueue()

    # Fire after drain so reg.lock is free — FFI-thread would deadlock here.
    if not notifiedStuck and ctx.eventQueueStuck.load():
      onNotResponding(ctx)
      notifiedStuck = true

    if not ctx.running.load():
      break
    hb.check(ctx)

proc eventThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## Owns queued `c_malloc` payloads until dispatch returns.
  defer:
    let fireRes = ctx.eventThreadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire eventThreadExitSignal", err = fireRes.error

  try:
    waitFor eventRun(ctx)
  except CatchableError as e:
    error "event thread exited with exception", error = e.msg

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
    return err("couldn't create " & name & " ThreadSignalPtr: " & $error)

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
    return err("error signaling " & name & ": " & $error)
  if not fired:
    return err("failed to signal " & name & " on time")
  ok()

proc waitExitOrErr(
    sig: ThreadSignalPtr, name: string, timeout: Duration
): Result[void, string] =
  let exited = sig.waitSync(timeout).valueOr:
    return err("error waiting for " & name & " exit: " & $error)
  if not exited:
    return err(name & " did not exit in time; leaking ctx to avoid hang")
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

proc clearContext[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Stops a heap-allocated FFI context.
  ctx.stopAndJoinThreads().isOkOr:
    return err("clearContext: " & $error)
  ctx.cleanUpResources().isOkOr:
    return err("cleanUpResources failed: " & $error)
  ok()
