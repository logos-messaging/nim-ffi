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
    # drains the bounded event queue and runs the heartbeat health check;
    # replaces the previous standalone watchdog thread
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr FFIThreadRequest]
  reqSignal: ThreadSignalPtr # to notify the FFI Thread that a new request is sent
  reqReceivedSignal: ThreadSignalPtr
    # to signal main thread, interfacing with the FFI thread, that FFI thread received the request
  stopSignal: ThreadSignalPtr
    # fired by destroyFFIContext so both ffiThread and eventThread can exit promptly
  threadExitSignal: ThreadSignalPtr
    # fired by ffiThread just before it exits; destroyFFIContext waits on
    # this with a bounded timeout instead of joining unconditionally, so a
    # blocked event loop cannot hang the caller forever
  eventQueueSignal: ThreadSignalPtr
    # fired by the FFI thread (via the dispatch templates) when it enqueues
    # an event, so the event thread wakes promptly instead of waiting out
    # the tick interval
  eventThreadExitSignal: ThreadSignalPtr
    # fired by the event thread just before it exits; mirrors threadExitSignal
    # so destroyFFIContext can do a bounded wait on the event thread too
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  eventQueue*: EventQueue
    # bounded SPSC ring; the FFI thread is the only producer, the event
    # thread the only consumer
  ffiHeartbeat*: Atomic[int64]
    # advanced by the FFI thread on every iteration of its main loop; the
    # event thread reads it to detect a wedged FFI thread (>1s without an
    # advance after the start-grace window) and fires onNotResponding
  eventQueueStuck*: Atomic[bool]
    # sticky overflow flag — once the queue saturates, sendRequestToFFIThread
    # rejects further calls so the library can't dig itself deeper
  running: Atomic[bool] # To control when the threads are running
  registeredRequests: ptr Table[cstring, FFIRequestProc]
    # Pointer to with the registered requests at compile time

var onFFIThread* {.threadvar.}: bool
  ## True while executing inside `ffiThreadBody`. Used by
  ## `sendRequestToFFIThread` to detect re-entrant dispatch from a handler
  ## (which would self-deadlock on `reqReceivedSignal`).

const git_version* {.strdefine.} = "n/a"

const
  EventThreadTickInterval* = 1.seconds
    ## How often the event thread wakes to do a heartbeat check when no
    ## events are pending. The dispatch templates also fire
    ## `eventQueueSignal` on enqueue, so this only bounds the *idle*
    ## latency between consecutive heartbeat checks.
  FFIHeartbeatStartDelay* = 10.seconds
    ## Grace window after thread startup during which heartbeat stalls
    ## are ignored — gives the host library (waku / libp2p / …) time to
    ## come up before we start measuring liveness. Same value the old
    ## standalone watchdog used.
  FFIHeartbeatStaleThreshold* = 1.seconds
    ## Once past the start delay, the FFI thread must advance its
    ## heartbeat at least once per this interval or it is considered
    ## blocked and onNotResponding fires.

type NotRespondingEvent* = object
  ## Empty CBOR payload — the event itself is the signal. Consumers
  ## discriminate on the surrounding `EventEnvelope.eventType`
  ## (`NotRespondingEventName`); this struct exists so the wire shape
  ## matches the typed-event contract every other `{.ffiEvent.}`
  ## produces (`{ eventType, payload }`).

const NotRespondingEventName* = "not_responding"
  ## Registry key and CBOR `eventType` for `onNotResponding`. Exposed so
  ## typed listeners can register against the same name the dispatch
  ## path uses, without depending on a string literal.

proc onNotResponding*(ctx: ptr FFIContext) =
  ## Fans out the "library is unhealthy" event to every listener
  ## registered for `not_responding` plus every wildcard listener. The
  ## payload is `EventEnvelope[NotRespondingEvent]`, CBOR-encoded once
  ## and reused across listeners — same wire shape as
  ## `dispatchFFIEventCbor`.
  ##
  ## Synchronous, lock-during-invocation by design: this is the global
  ## "library is unhealthy" notification path and bypasses the event
  ## queue (which may itself be the thing that's stuck). The dispatch
  ## templates' lock-during-invocation contract is mirrored here.
  ##
  ## Cannot reuse `dispatchFFIEventCbor`: that template resolves the
  ## registry via the `ffiCurrentEventRegistry` threadvar, which is only
  ## set on the FFI thread. `onNotResponding` runs on the event thread,
  ## so it goes through `ctx[].eventRegistry` directly.
  withLock ctx[].eventRegistry.lock:
    let snap =
      ctx[].eventRegistry.byEvent.getOrDefault(NotRespondingEventName) &
      ctx[].eventRegistry.wildcard
    if snap.len == 0:
      chronicles.debug "onNotResponding - no listener registered"
      return
    foreignThreadGc:
      try:
        let event = cborEncode(
          EventEnvelope[NotRespondingEvent](
            eventType: NotRespondingEventName, payload: NotRespondingEvent()
          )
        )
        for listener in snap:
          listener.callback(
            RET_OK,
            cast[ptr cchar](unsafeAddr event[0]),
            cast[csize_t](event.len),
            listener.userData,
          )
      except Exception, CatchableError:
        let msg =
          "Exception dispatching " & NotRespondingEventName & ": " &
          getCurrentExceptionMsg()
        for listener in snap:
          listener.callback(
            RET_ERR,
            cast[ptr cchar](unsafeAddr msg[0]),
            cast[csize_t](msg.len),
            listener.userData,
          )

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
): Result[void, string] =
  # Issue #6: once the event queue has overflowed we stop accepting new
  # requests entirely, on the assumption that any further work will just
  # produce more events the listener side already can't keep up with.
  # Stuck flag is sticky for the context lifetime — recovery requires
  # destroy + recreate, matching the issue's "expected malfunctioning".
  # NB: we deliberately do NOT call onNotResponding here. The event
  # thread fires it once when it observes the stuck flag (its loop is
  # the only place where reg.lock is guaranteed not to be held by an
  # in-flight listener); calling it from a foreign thread would
  # deadlock against a back-pressuring listener mid-invocation.
  if ctx.eventQueueStuck.load():
    deleteRequest(ffiRequest)
    return err("event queue stuck - library cannot accept new requests")

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

# ---------------------------------------------------------------------------
# Heartbeat-aware closure capturing for the dispatch threadvar hook
# ---------------------------------------------------------------------------

var ffiEventQueueSignalPtr {.threadvar.}: ThreadSignalPtr
  ## Stash for the event-thread wakeup signal. Captured here so the
  ## notify-enqueued hook below has no closure environment.

proc ffiNotifyEventEnqueuedHook() {.gcsafe, raises: [].} =
  ## Wakes the event thread immediately after a successful enqueue so
  ## the listener fan-out latency isn't bounded by the tick interval.
  if not ffiEventQueueSignalPtr.isNil():
    let res = ffiEventQueueSignalPtr.fireSync()
    if res.isErr():
      # The event thread will still see the queue depth on the next
      # tick; logging is enough to flag a misconfigured signal fd.
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
      # Heartbeat: the event thread reads this to confirm the FFI thread
      # isn't wedged. The 100 ms `reqSignal.wait` below means we advance
      # at least ~10x per second under any normal load; a sync handler
      # that blocks the dispatcher will freeze the counter, which is
      # exactly the failure mode the watchdog used to detect.
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
        error "draining pending FFI requests on shutdown raised", error = exc.msg

  waitFor ffiRun(ctx)

proc eventThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## Drains the bounded event queue and runs the FFI-thread heartbeat
  ## health check. Replaces the standalone watchdog thread: the event
  ## thread checks liveness in-band (no probe request round-trip), and
  ## the dispatch templates' queue-overflow path is the second trigger
  ## for `onNotResponding`.
  ##
  ## The queue stores raw `c_malloc` payloads + names; this thread owns
  ## them for the duration of dispatch and frees them after the listener
  ## fan-out returns.

  defer:
    # Best-effort: tell stopAndJoinThreads we've exited so its bounded
    # wait unblocks. If this fails we still exit; the caller's timeout
    # path will take over.
    let fireRes = ctx.eventThreadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire eventThreadExitSignal", err = fireRes.error

  let eventRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    let startedAt = Moment.now()
    var lastHeartbeat = ctx.ffiHeartbeat.load()
    var lastHeartbeatChange = Moment.now()
    var notifiedStale = false
    var notifiedStuck = false

    while ctx.running.load():
      # Wake on either an enqueue (eventQueueSignal) or the tick interval —
      # whichever comes first. The signal path keeps dispatch latency low
      # under load; the timeout path bounds idle latency for the
      # heartbeat check.
      discard await ctx.eventQueueSignal.wait().withTimeout(EventThreadTickInterval)

      # Drain whatever is currently in the queue. Each iteration:
      #   1. Pop one event (queue lock).
      #   2. Snapshot listeners + invoke them under reg.lock — the
      #      lock-during-invocation contract from PR #39 / issue #40 is
      #      preserved here: a foreign `removeEventListener` blocks
      #      until the in-flight callback fan-out returns.
      #   3. Free the payload.
      while true:
        let opt = ctx.eventQueue.tryDequeueEvent()
        if opt.isNone:
          break
        let qe = opt.get()
        defer:
          if not qe.name.isNil:
            c_free(cast[pointer](qe.name))
          if not qe.data.isNil:
            c_free(qe.data)

        withLock ctx[].eventRegistry.lock:
          let snap =
            ctx[].eventRegistry.byEvent.getOrDefault($qe.name) &
            ctx[].eventRegistry.wildcard
          if snap.len == 0:
            chronicles.debug "event has no listeners", event = $qe.name
          else:
            foreignThreadGc:
              try:
                for listener in snap:
                  listener.callback(
                    RET_OK,
                    cast[ptr cchar](qe.data),
                    cast[csize_t](qe.dataLen),
                    listener.userData,
                  )
              except Exception, CatchableError:
                let msg =
                  "Exception dispatching " & $qe.name & ": " & getCurrentExceptionMsg()
                for listener in snap:
                  listener.callback(
                    RET_ERR,
                    cast[ptr cchar](unsafeAddr msg[0]),
                    cast[csize_t](msg.len),
                    listener.userData,
                  )

      # Queue-overflow notification: the FFI thread can only set the
      # sticky flag (firing onNotResponding from there would deadlock
      # against a back-pressuring listener that's holding reg.lock on
      # this thread). We fire it once from here, after the drain loop,
      # so the slow listener has already released the lock.
      if not notifiedStuck and ctx.eventQueueStuck.load():
        onNotResponding(ctx)
        notifiedStuck = true

      # Heartbeat staleness check. Skipped during the start-delay grace
      # window so a slow library bring-up doesn't fire a spurious
      # not_responding. Once we've fired, latch `notifiedStale` until
      # the FFI thread proves it's alive again — avoids spamming the
      # listener while the FFI thread is still stuck.
      if not ctx.running.load():
        break
      if Moment.now() - startedAt <= FFIHeartbeatStartDelay:
        continue

      let cur = ctx.ffiHeartbeat.load()
      if cur != lastHeartbeat:
        lastHeartbeat = cur
        lastHeartbeatChange = Moment.now()
        notifiedStale = false
      elif not notifiedStale and
          Moment.now() - lastHeartbeatChange > FFIHeartbeatStaleThreshold:
        onNotResponding(ctx)
        notifiedStale = true

  try:
    waitFor eventRun(ctx)
  except CatchableError as exc:
    error "event thread exited with exception", error = exc.msg

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`: tears down the lock, registry,
  ## queue, and signal fds in place. The caller is responsible for the
  ## memory holding `ctx` (free it for heap allocations, return it to the
  ## pool for slot-allocated contexts). Threads MUST already be joined.
  ##
  ## Each field is nil'd after close so a subsequent re-init on the same
  ## storage (pool slot reuse) doesn't double-close a stale pointer if
  ## init's deferred cleanup runs.
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
  return ctx.deinitContextResources()

proc initContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Initialises all resources inside an already-allocated FFIContext slot.
  ## On failure every partially-initialised resource is closed; the caller
  ## is responsible for releasing the slot (freeShared or pool.releaseSlot).
  ##
  ## Defensive: a reused pool slot still holds the previous lifetime's
  ## signal pointers (set to nil by `deinitContextResources` on destroy,
  ## but explicit here in case a future path forgets). Nil before
  ## allocating so the deferred cleanup never double-closes.
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
  return ok()

proc signalStop*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ctx.running.store(false)
  # We deliberately do NOT call onNotResponding from these error paths:
  # the event thread may be stuck mid-callback holding `eventRegistry.lock`,
  # and onNotResponding takes that same lock — exactly the scenario the
  # bounded-timeout caller needs to escape from, not amplify into a deadlock.
  let reqSignaled = ctx.reqSignal.fireSync().valueOr:
    return err("error signaling reqSignal in signalStop: " & $error)
  if not reqSignaled:
    return err("failed to signal reqSignal on time in signalStop")
  let stopSignaled = ctx.stopSignal.fireSync().valueOr:
    return err("error signaling stopSignal in signalStop: " & $error)
  if not stopSignaled:
    return err("failed to signal stopSignal on time in signalStop")
  # Wake the event thread so it observes `running == false` immediately
  # instead of waiting out the tick interval. fireSync failing here is
  # not fatal — the event thread will still notice on the next tick — so
  # we only log and continue.
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
  ## Signals the FFI and event threads to stop, waits up to ThreadExitTimeout
  ## for each to exit, and joins them. On timeout returns err and skips the
  ## remaining joinThread (leaving the threads live) rather than hanging the
  ## caller. Resource cleanup (signal fds, lock) is the caller's
  ## responsibility.
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  # We deliberately do NOT call onNotResponding from the timeout paths:
  # the event thread may be stuck mid-callback holding `eventRegistry.lock`,
  # and onNotResponding takes that same lock — exactly the scenario the
  # bounded-timeout caller needs to escape from, not amplify into a deadlock.
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
