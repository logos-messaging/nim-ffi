## FFI-thread body and request submission API.
##
## Included from `ffi_context.nim` — inherits its imports, FFIContext type,
## and the `onFFIThread` threadvar. Companion to `event_thread.nim`.
##
## Responsibilities:
## - Receive `FFIThreadRequest`s from foreign threads via `reqChannel` and
##   dispatch them through the user-registered handler table.
## - Advance `ctx.ffiHeartbeat` each loop iteration so the event thread can
##   detect a wedged FFI thread.

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
): Result[void, string] =
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

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## FFI thread body that attends library user API requests
  ffiCurrentEventRegistry = addr ctx[].eventRegistry
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
        error "draining pending FFI requests on shutdown raised", error = exc.msg

  waitFor ffiRun(ctx)
