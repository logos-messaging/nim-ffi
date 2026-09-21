## FFI-thread body and request submission API. Included from `ffi_context.nim`.
## Dispatches `FFIThreadRequest`s from `reqQueueBank` and advances
## `ctx.ffiHeartbeat` so the host's poller can spot a wedged FFI thread.

## Compile-time-populated table: request type name (cstring) -> async handler.
## Public because `{.ffi.}`/`registerReqFFI` expand a write to it in the caller's
## module; every write lands during module init, before any FFI thread exists.
var registeredRequests*: Table[cstring, FFIRequestProc]

let registeredRequestsPtr = addr registeredRequests
  ## Read path of every FFI thread; the pointer keeps a `{.gcsafe.}` handler off the GC'ed global, which nothing writes after init.

const MaxOutstandingRequests* {.intdefine: "ffiMaxOutstandingRequests".} = 16384
  ## Requests a context holds that the host has not collected the reply of. Replies
  ## are never dropped, so this is what bounds a host that submits and never polls.
  ## Override with `-d:ffiMaxOutstandingRequests=<n>`.

proc refuse(request: ptr FFIThreadRequest, code: cint, why: string): cint =
  deleteRequest(request)
  setLastError(why)
  return code

proc submitRequest*(
    ctx: ptr FFIContext,
    ffiRequest: ptr FFIThreadRequest,
    generation: uint,
    reqIdOut: ptr uint64,
): cint =
  ## Queues the request for the FFI thread. `RET_OK` promises exactly one reply
  ## carrying `reqIdOut[]`, unless the context closes first; any other code means
  ## no reply comes, and `lastError()` says why. `generation` is the claim the
  ## caller resolved its token under; the request carries it so a slot that changes
  ## owner between the resolve and the dispatch answers nobody.

  # A nil request means the allocator failed; report it instead of dereferencing.
  if ffiRequest.isNil():
    setLastError("out of memory: could not allocate the FFI request")
    return RET_ERR

  if reqIdOut.isNil():
    return
      refuse(ffiRequest, RET_ERR, "req_id_out is NULL: the reply could not be matched")

  if ctx.eventQueueStuck.load():
    return refuse(
      ffiRequest, RET_QUEUE_FULL,
      "event queue stuck - library cannot accept new requests",
    )

  if onFFIThread:
    # A handler re-dispatching onto its own FFI thread would deadlock; reject.
    return refuse(
      ffiRequest, RET_ERR,
      "reentrant ffi call: a handler invoked sendRequestToFFIThread on its own context",
    )

  if ctx.lifecycle.load() != CtxLifecycle.Active:
    return refuse(
      ffiRequest, RET_ERR, "FFI context is not accepting requests (being recycled)"
    )

  ffiRequest.generation = generation
  if generation != ctx.currentGeneration():
    return refuse(
      ffiRequest, RET_INVALID_CTX,
      "FFI context was recycled; the token names an owner that is gone",
    )

  let payloadLen = ffiRequest[].dataLen
  if payloadLen > MaxRequestPayloadBytes:
    return refuse(
      ffiRequest,
      RET_TOO_LARGE,
      "request payload of " & $payloadLen & " bytes exceeds the " &
        $MaxRequestPayloadBytes & " byte cap",
    )

  if ctx[].outbound.outstanding.fetchAdd(1) >= MaxOutstandingRequests:
    ctx[].outbound.outstanding.atomicDec()
    return refuse(
      ffiRequest,
      RET_QUEUE_FULL,
      $MaxOutstandingRequests & " requests wait for the host to poll their replies",
    )

  # Before the push: the reply can reach a poller before this call returns.
  ffiRequest.reqId = ctx.nextReqId.fetchAdd(1) + 1
  reqIdOut[] = ffiRequest.reqId

  # Wake only when the push found the queue empty: waking per submit kills scaling, and a skipped wake just waits the consumer's 100ms poll.
  case ctx.reqQueueBank.pushRequest(ffiRequest)
  of QueueFull:
    ctx[].outbound.outstanding.atomicDec()
    # The id was handed out for a reply that will not come; take it back.
    reqIdOut[] = 0
    return refuse(
      ffiRequest,
      RET_QUEUE_FULL,
      "request queue full: " & $RequestQueueDepth & " requests already queued",
    )
  of Queued:
    discard
  of QueuedWake:
    # A failed wake is non-fatal (poll-drain still dispatches); erroring here would answer twice a request that still completes.
    ctx.reqSignal.fireSync().isOkOr:
      error "failed to wake FFI thread after enqueue (request still queued)",
        error = error

  return RET_OK

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, generation: uint
): Result[uint64, string] =
  ## `submitRequest` for Nim callers: the request id, or the refusal as text.
  var reqId: uint64
  if submitRequest(ctx, ffiRequest, generation, addr reqId) != RET_OK:
    return err($lastError())
  return ok(reqId)

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest
): Result[uint64, string] =
  ## For a caller holding the context itself (a ctor, the static ctx, a test): no token, so the live claim is the generation to stamp.
  sendRequestToFFIThread(ctx, ffiRequest, ctx.currentGeneration())

proc awaitWithStaleWarnings(
    retFut: Future[Result[seq[byte], string]],
    request: ptr FFIThreadRequest,
    outb: ptr FFIOutbound,
    interval: Duration,
    reqTypeName: string,
): Future[Result[seq[byte], string]] {.async.} =
  ## Queues a stale warning every `interval` while the handler runs, then returns
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
    warn "ffi request still in flight; the host is told through a stale warning",
      request = reqTypeName, elapsedMs = elapsed
    enqueueStaleWarn(outb[], request, elapsed)
  return await retFut

proc processRequest[T](
    request: ptr FFIThreadRequest, ctx: ptr FFIContext[T]
) {.async.} =
  ## Processes one request on the FFI thread.

  let reqTypeName = $request[].reqTypeName
  let reqTypeNameCs = reqTypeName.cstring # keeps reqTypeName alive

  let retFut =
    if not registeredRequestsPtr[].contains(reqTypeNameCs):
      nilProcess(request[].reqTypeName)
    else:
      registeredRequestsPtr[][reqTypeNameCs](cast[pointer](request), ctx)

  # One try over warn-loop + handler so a shutdown-drain cancel still reaches the reply below.
  let res =
    try:
      await awaitWithStaleWarnings(
        retFut, request, addr ctx[].outbound, ctx.staleWarnInterval, reqTypeName
      )
    except CatchableError as e:
      Result[seq[byte], string].err(
        "Error in processRequest for " & reqTypeName & ": " & e.msg
      )

  # The request becomes its own reply; the poller frees it once the host is done with it.
  setReply(request, res)
  enqueueReply(ctx[].outbound, request)

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
  ## Fails every queued request instead of dispatching it: running one after the
  ## slot is reused would run it against the library of the next owner.
  var request = ctx.reqQueueBank.mergeQueues()
  while not request.isNil():
    let nextRequest = request[].next # read before the reply queue relinks it
    if request[].generation != ctx.currentGeneration():
      ctx[].outbound.retireRequest(request)
      request = nextRequest
      continue
    setReply(request, Result[seq[byte], string].err(RecycledReason))
    enqueueReply(ctx[].outbound, request)
    request = nextRequest

type TeardownOutcome = enum
  ## Skipped is clean: there was nothing to tear down.
  Skipped
  Completed
  TimedOut
  Raised

proc runTeardown[T](ctx: ptr FFIContext[T]): Future[TeardownOutcome] {.async.} =
  ## Awaits the library's `{.ffiDtor.}` body. `libReady` gates it: without a ctor
  ## `myLib` is the zero-valued fallback, nil for a `ref` type.
  let teardown = ffiTeardownHook[T]()
  if teardown.isNil() or ctx.myLib.isNil() or not ctx.libReady.load():
    debug "no library teardown to run for this context"
    return TeardownOutcome.Skipped
  try:
    # `withTimeout` cancels the body and waits for the unwind: no teardown code runs past this await.
    let done = await teardown(ctx.myLib).withTimeout(TeardownTimeout)
    if done:
      return TeardownOutcome.Completed
    error "the timeout cancelled the library teardown; work it did not cancel " &
      "still runs on this thread", timeoutMs = TeardownTimeoutMs
    return TeardownOutcome.TimedOut
  except CatchableError as e:
    error "library teardown raised", error = e.msg
    return TeardownOutcome.Raised

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
  # A reused slot skips initContextResources, so the handle ids of the old owner
  # would otherwise resolve for the next one.
  ctx[].handles.releaseAll()
  # Same reason: the sticky overflow flag would reject every request of the next owner, ctor included.
  ctx.eventQueueStuck.store(false)
  rejectQueuedRequests(ctx)
  # The owner's poller gets `RET_CLOSED`; what it did not collect is dropped, the
  # rejections above included, so the next owner never sees a message of this one.
  closeOutbound(ctx[].outbound, ctx.currentGeneration())
  dropQueuedMessages(ctx[].outbound, ctx[].eventQueue)
  ongoing[].setLen(0)

proc finishRecycle[T](ctx: ptr FFIContext[T], failure: RecycleFailure) =
  ## Ends a recycle: quarantines the slot or releases it, and answers the caller
  ## either way. Fire before the release, or a thread claiming the slot would
  ## take this as its own answer.
  # A caller whose wait expired already saw a failure, so the slot must not come back; the race on the flag is benign, a lost race releases only a slot whose teardown completed.
  var outcome = failure
  if outcome == RecycleFailure.None and ctx.recycleAbandoned.load():
    outcome = RecycleFailure.CallerAbandoned
  if outcome != RecycleFailure.None:
    ctx.recycleFailure.store(outcome)
    ctx.lifecycle.store(CtxLifecycle.RecycleFailed)
    error "context quarantined; the pool slot and its threads leak, and the " &
      "library stays alive", reason = outcome.reason(), cause = $outcome
    closeOutbound(ctx[].outbound, ctx.currentGeneration())
  let fireRes = ctx.recycleDoneSignal.fireSync()
  if fireRes.isErr():
    error "failed to fire recycleDoneSignal", err = fireRes.error
  if outcome == RecycleFailure.None:
    ctx.releaseClaim()

proc recycleContext[T](
    ctx: ptr FFIContext[T], ongoing: ptr seq[Future[void]]
) {.async.} =
  ## Drain in-flight handlers, run the library teardown, reset the slot, then fire recycleDoneSignal and release the slot, all WITHOUT stopping the worker/event threads, so the next createFFIContext reuses them (no fd churn). Anything short of a completed teardown quarantines the slot instead: it stays claimed for the life of the process, the library stays alive, and `recycleFailure` tells the host why. Reuse is safe only when the previous owner is gone from this thread, and the one proof is a teardown that ran to the end; chronos cannot enumerate or cancel what a cut-short teardown left on the dispatcher.
  var failure = RecycleFailure.None
  # Deferred so a raise out of the teardown cannot strand the slot.
  defer:
    ctx.finishRecycle(failure)

  if not await drainOngoing(ongoing):
    # A handler that still runs must not find its library freed under it.
    error "recycle drain timed out; the teardown never ran",
      inFlight = ongoing[].len, timeoutMs = RecycleTimeoutMs
    failure = RecycleFailure.DrainTimeout
    return

  # Before the reset: the teardown hook still needs `myLib` and its listeners.
  case await runTeardown(ctx)
  of TeardownOutcome.Skipped, TeardownOutcome.Completed:
    discard
  of TeardownOutcome.TimedOut:
    failure = RecycleFailure.TeardownTimeout
    return
  of TeardownOutcome.Raised:
    failure = RecycleFailure.TeardownRaised
    return

  # Reset only now: the previous owner is provably done with this thread.
  resetForNextOwner(ctx, ongoing)

var ffiCurrentOutbound {.threadvar.}: ptr FFIOutbound
  # Stashed so the hook has no closure env.
var ffiCurrentGeneration {.threadvar.}: ptr Atomic[uint]

proc ffiHostPollsHook(): bool {.gcsafe, raises: [].} =
  if ffiCurrentOutbound.isNil() or ffiCurrentGeneration.isNil():
    return true
  return ffiCurrentOutbound[].polledGeneration.load() == ffiCurrentGeneration[].load()

proc ffiNotifyEventEnqueuedHook() {.gcsafe, raises: [].} =
  if not ffiCurrentOutbound.isNil():
    notifyOutbound(ffiCurrentOutbound[])

proc proveAlive(ctx: ptr FFIContext) =
  ## Advance the heartbeat the poller reads; only movement matters, not value.
  ctx.ffiHeartbeat.atomicInc()

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  registerCloseDispatcherHook()
  ffiCurrentEventQueue = addr ctx[].eventQueue
  ffiCurrentEventQueueStuck = addr ctx[].eventQueueStuck
  ffiCurrentMsgSeq = addr ctx[].outbound.msgSeq
  ffiCurrentOutbound = addr ctx[].outbound
  ffiCurrentGeneration = addr ctx[].generation
  ffiCurrentNotifyEventEnqueued = ffiNotifyEventEnqueuedHook
  ffiCurrentHostPolls = ffiHostPollsHook
  onFFIThread = true

  defer:
    onFFIThread = false
    unregisterWaitedSignal(ctx.reqSignal)
    # Free handle refs on the thread that allocated them (refc heap is thread-local).
    ctx[].handles.releaseAll()
    # After the teardown, so its events still reach the poller before `RET_CLOSED`.
    closeOutbound(ctx[].outbound, ctx.currentGeneration())
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
            # A past owner submitted this, and nobody polls for that owner any more.
            ctx[].outbound.retireRequest(request)
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

      # Drain before blocking: the wake of the submit that made this slot active
      # again was consumed by the wait in the branch above, so a queue checked
      # only after the next wait would sit there for the fallback timeout.
      processQueue()

      # Block until a submit signals us, or at most 100ms.
      discard await ctx.reqSignal.wait().withTimeout(chronos.milliseconds(100))

    # Drain once more for requests enqueued just before `running` flipped.
    processQueue()
    cleanFinishedRequests()
    if pending.len > 0:
      try:
        await allFutures(pending)
      except CatchableError as e:
        error "draining pending FFI requests on shutdown raised", error = e.msg

    # The thread stops either way; runTeardown already logged the outcome.
    discard await runTeardown(ctx)

  waitFor ffiRun(ctx)
