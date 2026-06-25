## FFI-thread body and request submission API.
##
## Included from `ffi_context.nim` — inherits its imports, FFIContext type,
## and the `onFFIThread` threadvar. Companion to `event_thread.nim`.
##
## Responsibilities:
## - Receive `FFIThreadRequest`s from foreign threads via `reqQueue` (a
##   lock-free MPSC queue) and dispatch them through the user-registered
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

  # Lock-free hand-off: the queue is unbounded so enqueue can't fail, and the
  # request's completion is reported asynchronously through its own callback —
  # no shared accept-ack, so concurrent producers never serialise here.
  ctx.reqQueue.push(ffiRequest)

  # A failed wake is non-fatal: the request is queued and the FFI thread's
  # poll-drain dispatches it within one tick regardless of the signal. Return
  # ok so the caller doesn't fire its error callback for a request that will
  # still complete normally — returning err here would double-fire the callback.
  ctx.reqSignal.fireSync().isOkOr:
    error "failed to wake FFI thread after enqueue (request still queued)",
      error = error

  ok()

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

  # CatchableError covers CancelledError from the shutdown drain; handleRes must still run.
  let res =
    try:
      await retFut
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
    # Unblocks destroyFFIContext's bounded wait so cleanup can proceed.
    let fireRes = ctx.threadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire threadExitSignal on FFI thread exit", err = fireRes.error

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    var ffiReqHandler: T # main library object (Waku, LibP2P, SDS, …)

    # Tracked so shutdown can drain them; abandoning a mid-await future leaks the request.
    var pending: seq[Future[void]] = @[]

    proc reapCompleted() =
      var i = 0
      while i < pending.len:
        if not pending[i].finished():
          inc i
          continue
        pending.del(i)

    proc drainQueue() =
      ## Dispatch every request the producers have enqueued. fireSync coalesces,
      ## so one wake can stand for many submits — drain to empty, not one per
      ## wake, or queued requests would strand until the next signal.
      while true:
        let request = ctx.reqQueue.pop()
        if request.isNil():
          break
        # Tick per dispatch so a large backlog can't flatline the heartbeat and
        # trip the event thread's wedged-FFI-thread detection mid-drain.
        discard ctx.ffiHeartbeat.fetchAdd(1)
        if ctx.myLib.isNil():
          ctx.myLib = addr ffiReqHandler
        pending.add processRequest(request, ctx)

    while ctx.running.load():
      # Freezes if a sync handler blocks the dispatcher; event thread reads to detect wedged FFI thread.
      discard ctx.ffiHeartbeat.fetchAdd(1)

      reapCompleted()

      # Drain regardless of the wait outcome: a missed/coalesced signal must not
      # leave requests stranded, and the 100ms timeout bounds shutdown latency.
      discard await ctx.reqSignal.wait().withTimeout(100.milliseconds)
      drainQueue()

    # Drain once more so requests enqueued just before `running` flipped still
    # dispatch and each pending handler's deleteRequest defer runs before exit.
    drainQueue()
    reapCompleted()
    if pending.len > 0:
      try:
        await allFutures(pending)
      except CatchableError as e:
        error "draining pending FFI requests on shutdown raised", error = e.msg

  waitFor ffiRun(ctx)
