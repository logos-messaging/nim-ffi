## FFI-thread body and request submission API. Included from `ffi_context.nim`.
## Dispatches `FFIThreadRequest`s from `reqQueueBank` and advances
## `ctx.ffiHeartbeat` so the event thread can spot a wedged FFI thread.

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, generation: uint
): Result[void, string] =
  ## `generation` is the claim the caller resolved its token under; the request carries it so a slot that changes owner between the resolve and the dispatch answers nobody.

  # A nil request means the allocator failed; report it instead of dereferencing.
  if ffiRequest.isNil():
    return err("out of memory: could not allocate the FFI request")

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

  ffiRequest.generation = generation
  if generation != ctx.currentGeneration():
    deleteRequest(ffiRequest)
    return err("FFI context was recycled; the token names an owner that is gone")

  let payloadLen = ffiRequest[].dataLen
  if payloadLen > MaxRequestPayloadBytes:
    deleteRequest(ffiRequest)
    return err(
      "request payload of " & $payloadLen & " bytes exceeds the " &
        $MaxRequestPayloadBytes & " byte cap"
    )

  # Wake only when the push found the queue empty: waking per submit kills scaling, and a skipped wake just waits the consumer's 100ms poll.
  case ctx.reqQueueBank.pushRequest(ffiRequest)
  of QueueFull:
    deleteRequest(ffiRequest)
    return err("request queue full: " & $RequestQueueDepth & " requests already queued")
  of Queued:
    discard
  of QueuedWake:
    # A failed wake is non-fatal (poll-drain still dispatches); erroring here would double-fire the callback for a request that still completes.
    ctx.reqSignal.fireSync().isOkOr:
      error "failed to wake FFI thread after enqueue (request still queued)",
        error = error

  ok()

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest
): Result[void, string] =
  ## For a caller holding the context itself (a ctor, the static ctx, a test): no token, so the live claim is the generation to stamp.
  sendRequestToFFIThread(ctx, ffiRequest, ctx.currentGeneration())

proc awaitWithStaleWarnings(
    retFut: Future[Result[seq[byte], string]],
    request: ptr FFIThreadRequest,
    interval: Duration,
    reqId: string,
): Future[Result[seq[byte], string]] {.async.} =
  ## Pings RET_STALE_WARN every `interval` while the handler runs, then returns
  ## its real result. Never cancels the handler: a hard-cancel mid-call could
  ## leave the underlying library partially applied. A cancel of this future
  ## therefore waits for the handler too — the recycle drain counts this future,
  ## so an early unwind would report a slot as drained while its handler runs.
  let intervalMs = interval.milliseconds
  if intervalMs <= 0:
    return await noCancel(retFut)
  var elapsed = 0'i64
  while not retFut.finished():
    let timer = sleepAsync(interval)
    # `race` doesn't cancel the loser, so the handler keeps running.
    try:
      discard await race(retFut, timer)
    except CancelledError:
      if not timer.finished():
        await noCancel(timer.cancelAndWait())
      return await noCancel(retFut)
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

proc freeLib[T](ctx: ptr FFIContext[T]) {.gcsafe.} =
  ## Releases the library object the ctor stored in ctx.myLib. Only owned libs
  ## (createShared'd by a ctor) are freed; the worker's stack fallback is not.
  # A reused slot skips initContextResources, so the recycle path clears this.
  ctx.libReady.store(false)
  if not ctx.myLibOwned or ctx.myLib.isNil():
    ctx.myLib = nil
    return
  when not defined(gcRefc):
    try:
      {.cast(gcsafe).}:
        `=destroy`(ctx.myLib[])
    except Exception as e:
      error "destroying the library on recycle raised; freeing it anyway", error = e.msg
  else:
    when T is ref:
      if ctx.myLibRefd:
        GC_unref(ctx.myLib[])
        ctx.myLibRefd = false
  freeShared(ctx.myLib)
  ctx.myLib = nil
  ctx.myLibOwned = false

const RecycledReason =
  "FFI context was recycled before this request ran; the caller is gone"

proc rejectQueuedRequests[T](ctx: ptr FFIContext[T]) =
  ## Fails every queued request instead of dispatching it. A request that a
  ## destroyed context left behind still carries that host's `userData`, which
  ## the host has freed; running it would answer a dead callback, and running it
  ## after the slot is reused would run it against the library of the next owner.
  var request = ctx.reqQueueBank.mergeQueues()
  while not request.isNil():
    let nextRequest = request[].next # read before handleRes frees it
    if request[].generation != ctx.currentGeneration():
      deleteRequest(request)
      request = nextRequest
      continue
    try:
      handleRes(Result[seq[byte], string].err(RecycledReason), request)
    except Exception as e:
      error "rejecting a queued request raised", error = e.msg
    request = nextRequest

proc runTeardown[T](ctx: ptr FFIContext[T]) {.async.} =
  ## Awaits the library's `{.ffiDtor.}` body. `libReady` gates it: without a ctor
  ## `myLib` is the zero-valued fallback, nil for a `ref` type.
  let teardown = ffiTeardownHook[T]()
  if teardown.isNil() or ctx.myLib.isNil() or not ctx.libReady.load():
    return
  try:
    let done = await teardown(ctx.myLib).withTimeout(TeardownTimeout)
    if not done:
      error "library teardown cancelled at the timeout; releasing the library",
        timeoutMs = TeardownTimeoutMs
  except CatchableError as e:
    error "library teardown raised", error = e.msg

proc drainOngoing(ongoing: ptr seq[Future[void]]): Future[bool] {.async.} =
  ## Waits out the in-flight dispatchers, then cancels them and waits again.
  ## False when both rounds time out and handlers are still running.
  ongoing[].keepItIf(not it.finished())
  if ongoing[].len == 0:
    return true
  if await allFutures(ongoing[]).withTimeout(RecycleTimeout):
    return true
  for fut in ongoing[]:
    fut.cancelSoon()
  return await allFutures(ongoing[]).withTimeout(RecycleTimeout)

proc resetForNextOwner[T](ctx: ptr FFIContext[T], ongoing: ptr seq[Future[void]]) =
  freeLib(ctx)
  clearListeners(ctx[].eventRegistry)
  # A reused slot skips initContextResources, so the handle ids of the old owner
  # would otherwise resolve for the next one.
  ctx[].handles.releaseAll()
  rejectQueuedRequests(ctx)
  ongoing[].setLen(0)

proc recycleContext[T](
    ctx: ptr FFIContext[T], ongoing: ptr seq[Future[void]]
) {.async.} =
  ## Drain in-flight handlers, run the library teardown, reset the slot, then fire recycleDoneSignal and release the slot, all WITHOUT stopping the worker/event threads, so the next createFFIContext reuses them (no fd churn). A drain that times out aborts the recycle: the slot stays claimed, the library stays alive, and the terminal `RecycleFailed` tells the host so.
  var drained = false
  # Deferred: a raise out of the teardown must not strand the slot. Fire before the release, or a thread claiming the slot would take this as its own answer.
  defer:
    if not drained:
      ctx.lifecycle.store(CtxLifecycle.RecycleFailed)
    let fireRes = ctx.recycleDoneSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire recycleDoneSignal", err = fireRes.error
    if drained:
      ctx.releaseClaim()

  drained = await drainOngoing(ongoing)
  if not drained:
    # A handler that still runs answers a callback carrying userData the host
    # frees as soon as teardown reports success.
    error "recycle drain timed out; leaking the pool slot and keeping the library",
      inFlight = ongoing[].len, timeoutMs = RecycleTimeoutMs
    return

  # Before the reset: the teardown hook still needs `myLib` and its listeners.
  await runTeardown(ctx)
  resetForNextOwner(ctx, ongoing)

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
          if request[].generation != ctx.currentGeneration():
            # A past owner submitted this; its callback carries userData that host frees once its recycle returns ok, so drop it unanswered.
            deleteRequest(request)
            request = nextRequest
            continue
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

      # A submit that read `Active` just before the recycle can still land here.
      # Fail it rather than run it against the library of the next owner.
      if ctx.lifecycle.load() != CtxLifecycle.Active:
        rejectQueuedRequests(ctx)
        discard await ctx.reqSignal.wait().withTimeout(chronos.milliseconds(100))
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

    await runTeardown(ctx)

  waitFor ffiRun(ctx)
