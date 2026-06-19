## FFI-thread body and request submission API. Included from `ffi_context.nim`.
## Dispatches `FFIThreadRequest`s from `reqQueueBank` and advances
## `ctx.ffiHeartbeat` so the event thread can spot a wedged FFI thread.

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest
): Result[void, string] =
  if ctx.eventQueueStuck.load():
    deleteRequest(ffiRequest)
    return err("event queue stuck - library cannot accept new requests")

  if onFFIThread:
    # A handler re-dispatching onto its own FFI thread would deadlock; reject.
    deleteRequest(ffiRequest)
    return err(
      "reentrant ffi call: a handler invoked sendRequestToFFIThread on its own context"
    )

  if ctx.lifecycle.load() != CtxLifecycle.Active:
    deleteRequest(ffiRequest)
    return err("FFI context is not accepting requests (being recycled)")

  # Wake only when the push found the queue empty: waking per submit kills scaling, and a skipped wake just waits the consumer's 100ms poll.
  let shouldWake = ctx.reqQueueBank.pushRequest(ffiRequest)

  # A failed wake is non-fatal (poll-drain still dispatches); erroring here would double-fire the callback for a request that still completes.
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
  ## Pings RET_STALE_WARN every `interval` while the handler runs, then returns
  ## its real result. Never cancels the handler: a hard-cancel mid-call could
  ## leave the underlying library partially applied.
  let intervalMs = interval.milliseconds
  if intervalMs <= 0:
    return await retFut
  var elapsed = 0'i64
  while not retFut.finished():
    let timer = sleepAsync(interval)
    # `race` doesn't cancel the loser, so the handler keeps running.
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
  ## Processes one request on the FFI thread.

  let reqId = $request[].reqId
  let reqIdCs = reqId.cstring # keeps reqId alive

  let retFut =
    if not ctx[].registeredRequests[].contains(reqIdCs):
      nilProcess(request[].reqId)
    else:
      ctx[].registeredRequests[][reqIdCs](cast[pointer](request), ctx)

  # One try over warn-loop + handler so a shutdown-drain cancel still reaches the response-and-free below.
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

const RecycleTimeout = 1500.milliseconds
  ## Bounds how long the recycle handler waits for in-flight handlers before it
  ## cancels them, so a wedged handler cannot block reuse forever.

proc freeLib[T](ctx: ptr FFIContext[T]) {.gcsafe.} =
  ## Releases the library object the ctor stored in ctx.myLib. Only owned libs
  ## (createShared'd by a ctor) are freed; the worker's stack fallback is not.
  if not ctx.myLibOwned or ctx.myLib.isNil():
    ctx.myLib = nil
    return
  when not defined(gcRefc):
    try:
      {.cast(gcsafe).}:
        `=destroy`(ctx.myLib[])
    except Exception:
      discard
  else:
    when T is ref:
      if ctx.myLibRefd:
        GC_unref(ctx.myLib[])
        ctx.myLibRefd = false
  freeShared(ctx.myLib)
  ctx.myLib = nil
  ctx.myLibOwned = false

proc recycleContext[T](
    ctx: ptr FFIContext[T], ongoing: ptr seq[Future[void]]
) {.async.} =
  ## Drain in-flight handlers, free the lib, clear listeners and release the
  ## slot — all WITHOUT stopping the worker/event threads, so the next
  ## createFFIContext reuses them (no fd churn). Then fire recycleDoneSignal.
  ongoing[].keepItIf(not it.finished())
  var drained = ongoing[].len == 0
  if not drained:
    drained = await allFutures(ongoing[]).withTimeout(RecycleTimeout)
  if not drained:
    for fut in ongoing[]:
      if not fut.finished():
        fut.cancelSoon()
    drained = await allFutures(ongoing[]).withTimeout(RecycleTimeout)

  freeLib(ctx)
  clearListeners(ctx[].eventRegistry)
  ongoing[].setLen(0)
  ctx.release()

  let fireRes = ctx.recycleDoneSignal.fireSync()
  if fireRes.isErr():
    error "failed to fire recycleDoneSignal", err = fireRes.error

var ffiEventQueueSignalPtr {.threadvar.}: ThreadSignalPtr
  # Stashed so the hook has no closure env.

proc ffiNotifyEventEnqueuedHook() {.gcsafe, raises: [].} =
  if not ffiEventQueueSignalPtr.isNil():
    let res = ffiEventQueueSignalPtr.fireSync()
    if res.isErr():
      error "failed to fire eventQueueSignal after enqueue", err = res.error

proc proveAlive(ctx: ptr FFIContext) =
  ## Advance the heartbeat the event thread polls; only movement matters, not value.
  ctx.ffiHeartbeat.atomicInc()

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
    # Free handle refs on the thread that allocated them (refc heap is thread-local).
    ctx[].handles.releaseAll()
    # Let the event thread stop draining and exit; wake it so it notices now.
    ctx.ffiThreadExited.store(true)
    ctx.eventQueueSignal.fireSync().isOkOr:
      error "failed to wake event thread on FFI thread exit", err = error
    # Unblocks destroyFFIContext's bounded wait.
    let fireRes = ctx.threadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire threadExitSignal on FFI thread exit", err = fireRes.error

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    var ffiReqHandler: T # main library object (Waku, LibP2P, SDS, …)

    # Tracked so shutdown can drain them; abandoning a future leaks its request.
    var pending: seq[Future[void]] = @[]

    proc cleanFinishedRequests() =
      var i = 0
      while i < pending.len:
        if not pending[i].finished():
          inc i
          continue
        pending.del(i)

    proc processQueue() =
      ## Drain fully: one wake can stand for many submits.
      while true:
        var request = ctx.reqQueueBank.mergeQueues()
        if request.isNil():
          break
        while not request.isNil():
          let nextRequest = request[].next # read before processRequest frees it
          # Tick per dispatch so a backlog can't flatline the heartbeat mid-drain.
          ctx.proveAlive()
          if ctx.myLib.isNil():
            # Must stay inside the closure: keeps `ffiReqHandler` alive across awaits.
            ctx.myLib = addr ffiReqHandler

          pending.add processRequest(request, ctx)
          request = nextRequest

    while ctx.running.load():
      ctx.proveAlive()

      # Recycle requested by the ffiDtor: drain + free lib + release the slot,
      # keeping this thread alive for the next createFFIContext to reuse.
      var expected = CtxLifecycle.RecyclePending
      if ctx.lifecycle.compareExchange(expected, CtxLifecycle.Recycling):
        await recycleContext(ctx, addr pending)
        continue

      cleanFinishedRequests()

      # Block until a submit signals us, or at most 100ms.
      discard await ctx.reqSignal.wait().withTimeout(chronos.milliseconds(100))
      processQueue()

    # Drain once more for requests enqueued just before `running` flipped.
    processQueue()
    cleanFinishedRequests()
    if pending.len > 0:
      try:
        await allFutures(pending)
      except CatchableError as e:
        error "draining pending FFI requests on shutdown raised", error = e.msg

    # Run the library's async {.ffiDtor.} shutdown before join if one exists and a request populated `myLib`; exceptions logged, never propagated.
    let teardown = ffiTeardownHook[T]()
    if not teardown.isNil() and not ctx.myLib.isNil():
      try:
        await teardown(ctx.myLib)
      except CatchableError as e:
        error "library teardown raised on shutdown", error = e.msg

  waitFor ffiRun(ctx)
