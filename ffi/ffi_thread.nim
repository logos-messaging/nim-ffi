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
  if ctx.eventQueueStuck.load():
    deleteRequest(ffiRequest)
    return err("event queue stuck - library cannot accept new requests")

  if onFFIThread:
    # Re-entrant dispatch from a handler would self-deadlock on `reqReceivedSignal`.
    deleteRequest(ffiRequest)
    return err(
      "reentrant ffi call: a handler invoked sendRequestToFFIThread on its own context"
    )

  # Serialise the trySend + fireSync + waitSync — reqChannel is SP and reqReceivedSignal is shared.
  ctx.lock.acquire()
  defer:
    ctx.lock.release()

  if ctx.lifecycle.load() != CtxLifecycle.Active:
    deleteRequest(ffiRequest)
    return err("FFI context is not accepting requests (being recycled)")

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
    # FFI thread was signaled and owns the request; don't double-free.
    return err("Couldn't receive reqReceivedSignal signal")

  # On ok the FFI thread's processRequest deallocShared(req)'s.
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

    while ctx.running.load():
      # Freezes if a sync handler blocks the dispatcher; event thread reads to detect wedged FFI thread.
      discard ctx.ffiHeartbeat.fetchAdd(1)

      # Recycle requested by the ffiDtor: drain + free lib + release the slot,
      # keeping this thread alive for the next createFFIContext to reuse.
      var expected = CtxLifecycle.RecyclePending
      if ctx.lifecycle.compareExchange(expected, CtxLifecycle.Recycling):
        await recycleContext(ctx, addr pending)
        continue

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

    # Drain so each pending handler's deleteRequest defer runs before exit.
    reapCompleted()
    if pending.len > 0:
      try:
        await allFutures(pending)
      except CatchableError as e:
        error "draining pending FFI requests on shutdown raised", error = e.msg

  waitFor ffiRun(ctx)
