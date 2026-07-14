## FFI-thread body and request submission API.
##
## Included from `ffi_context.nim` — inherits its imports, FFIContext type,
## and the `onFFIThread` threadvar. Companion to `event_thread.nim`.
##
## Responsibilities:
## - Receive `FFIThreadRequest`s from foreign threads via `reqQueueBank` (a
##   mutex-guarded MPSC queue) and dispatch them through the user-registered
##   handler table.
## - Advance `ctx.ffiHeartbeat` each loop iteration so the event thread can
##   detect a wedged FFI thread.

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest
): Result[void, string] =
  if ctx.eventQueueStuck.load():
    deleteRequest(ffiRequest)
    return err("event queue stuck - library cannot accept new requests")

  if onFFIThread:
    # A handler re-dispatching onto its own FFI thread would enqueue work the
    # blocked dispatcher can never drain; reject instead of dead-locking.
    deleteRequest(ffiRequest)
    return err(
      "reentrant ffi call: a handler invoked sendRequestToFFIThread on its own context"
    )

  # The lock inside pushRequest covers only the O(1) enqueue; the wake stays
  # outside it, so concurrent producers don't serialise. Unbounded, so enqueue
  # can't fail — completion comes via the request's own callback, no accept-ack.
  #
  # Wake only when the push found the queue empty: while the consumer drains, a
  # fireSync() syscall per submit (contended across producers) is what destroys
  # scaling. A skipped wake can't strand the request — the consumer re-polls 100ms.
  let shouldWake = ctx.reqQueueBank.pushRequest(ffiRequest)

  # A failed wake is non-fatal: the request is queued and the poll-drain
  # dispatches it within a tick anyway. Returning err would double-fire the
  # caller's callback for a request that still completes.
  if shouldWake:
    ctx.reqSignal.fireSync().isOkOr:
      error "failed to wake FFI thread after enqueue (request still queued)",
        error = error

  ok()

proc awaitWithStaleWarnings(
    retFut: Future[Result[seq[byte], string]],
    request: ptr FFIThreadRequest,
    interval: Duration,
    reqId: string,
): Future[Result[seq[byte], string]] {.async.} =
  ## Pings the caller with RET_STALE_WARN every `interval` while the handler
  ## runs, then returns its real result. Never cancels it: a hard-cancel mid-call
  ## into the underlying library (Waku/libp2p) can leave it partially applied, so
  ## the caller is kept informed and decides for itself. The timer lives entirely
  ## in this frame, so nothing references the request once the handler resolves.
  let intervalMs = interval.milliseconds
  if intervalMs <= 0:
    # A non-positive / infinite interval opts out of progress pings entirely.
    return await retFut
  var elapsed = 0'i64
  while not retFut.finished():
    let timer = sleepAsync(interval)
    # `race` returns the first to finish WITHOUT cancelling the loser, so the
    # handler keeps running when the timer wins.
    discard await race(retFut, timer)
    if retFut.finished():
      if not timer.finished():
        await timer.cancelAndWait()
      break
    elapsed += intervalMs
    warn "ffi request still in flight; caller notified via RET_STALE_WARN",
      reqId = reqId, elapsedMs = elapsed
    fireStaleWarn(request, elapsed)
  return await retFut

proc processRequest[T](
    request: ptr FFIThreadRequest, ctx: ptr FFIContext[T]
) {.async.} =
  ## Invoked within the FFI thread to process a request coming from the FFI API consumer thread.

  let reqId = $request[].reqId
  let reqIdCs = reqId.cstring
    # keeps reqId alive; implicit string→cstring is a warning.

  let retFut =
    if not ctx[].registeredRequests[].contains(reqIdCs):
      nilProcess(request[].reqId)
    else:
      ctx[].registeredRequests[][reqIdCs](cast[pointer](request), ctx)

  # CatchableError covers CancelledError from the shutdown drain. The warn loop
  # and the handler share one try so that a cancel mid-loop still reaches the
  # response-and-free below.
  let res =
    try:
      await awaitWithStaleWarnings(retFut, request, ctx.staleWarnInterval, reqId)
    except CatchableError as e:
      Result[seq[byte], string].err(
        "Error in processRequest for " & reqId & ": " & e.msg
      )

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

proc proveAlive(ctx: ptr FFIContext) =
  ## Advance the heartbeat the event thread polls to spot a wedged FFI thread.
  ## Only that the counter keeps moving matters, never its value — so a plain
  ## atomic increment, no read-back.
  ctx.ffiHeartbeat.atomicInc()

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
    # Free handle refs on the FFI thread that allocated them (refc heap is thread-local).
    ctx[].handles.releaseAll()
    # Teardown has run and no more events will be emitted from this thread; let
    # the event thread stop draining and exit. Wake it so it notices without
    # waiting a full tick.
    ctx.ffiThreadExited.store(true)
    ctx.eventQueueSignal.fireSync().isOkOr:
      error "failed to wake event thread on FFI thread exit", err = error
    # Unblocks destroyFFIContext's bounded wait so cleanup can proceed.
    let fireRes = ctx.threadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire threadExitSignal on FFI thread exit", err = fireRes.error

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    var ffiReqHandler: T # main library object (Waku, LibP2P, SDS, …)

    # Tracked so shutdown can drain them; abandoning a mid-await future leaks the request.
    var pending: seq[Future[void]] = @[]

    proc cleanFinishedRequests() =
      var i = 0
      while i < pending.len:
        if not pending[i].finished():
          inc i
          continue
        pending.del(i)

    proc processQueue() =
      ## Process enqueued requests until the queue is empty. A single wake can
      ## stand for many submits, so we drain fully rather than once per wake —
      ## otherwise queued requests would sit until the next wake.
      while true:
        var request = ctx.reqQueueBank.mergeQueues()
        if request.isNil():
          break
        while not request.isNil():
          let nextRequest = request[].next # read before processRequest frees it
          # Tick per dispatch so a large backlog can't flatline the heartbeat
          # and trip the event thread's wedged-FFI-thread detection mid-drain.
          ctx.proveAlive()
          if ctx.myLib.isNil():
            # This reference must stay inside the closure: it's what keeps
            # `ffiReqHandler` in the async env, so `myLib` survives across awaits.
            ctx.myLib = addr ffiReqHandler

          pending.add processRequest(request, ctx)
          request = nextRequest

    while ctx.running.load():
      # Freezes if a sync handler blocks the dispatcher; event thread reads to detect wedged FFI thread.
      ctx.proveAlive()

      cleanFinishedRequests()

      # Block until a submit signals us, or for at most 100ms if none does.
      discard await ctx.reqSignal.wait().withTimeout(chronos.milliseconds(100))
      processQueue()

    # Drain once more so requests enqueued just before `running` flipped still
    # dispatch and each pending handler's deleteRequest defer runs before exit.
    processQueue()
    cleanFinishedRequests()
    if pending.len > 0:
      try:
        await allFutures(pending)
      except CatchableError as e:
        error "draining pending FFI requests on shutdown raised", error = e.msg

    # In-flight requests drained; run the library's async shutdown (e.g.
    # `switch.stop()`) on this event loop before the thread joins. Only if a
    # `{.ffiDtor.}` registered a hook and a request populated `myLib`. Exceptions
    # are logged, never propagated: the thread must still fire threadExitSignal.
    let teardown = ffiTeardownHook[T]()
    if not teardown.isNil() and not ctx.myLib.isNil():
      try:
        await teardown(ctx.myLib)
      except CatchableError as e:
        error "library teardown raised on shutdown", error = e.msg

  waitFor ffiRun(ctx)
