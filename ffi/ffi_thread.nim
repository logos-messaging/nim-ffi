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

  # Reject once recycling has been requested: the slot is being drained/parked
  # and its handler table/lib are about to be torn down. requestRecycle flips
  # this under the same lock, so the check is race-free.
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

  # The request is now owned by the FFI thread: it has been queued and the FFI
  # thread signaled, so it WILL be received, processed, and answered through the
  # callback via handleRes. The waitSync below only confirms prompt receipt; its
  # failure (e.g. EINVAL/EINTR under load or signal teardown) must NOT be
  # surfaced as an error, or the caller would fire the callback a SECOND time
  # while handleRes also fires it — a double callback onto a freed response.
  let res = ctx.reqReceivedSignal.waitSync(timeout)
  if res.isErr():
    return ok()

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

proc freeLib[T](ctx: ptr FFIContext[T]) {.gcsafe.} =
  ## Frees the createShared'd library object built by the ctor. Logical resource
  ## cleanup is the destructor body's job; this only releases the Nim storage.
  if ctx.myLib.isNil():
    return
  when not defined(gcRefc):
    {.cast(gcsafe).}:
      `=destroy`(ctx.myLib[])
  else:
    discard
  freeShared(ctx.myLib)
  ctx.myLib = nil

var RecycleTimeout* = 1500.milliseconds
  ## Upper bound the recycle handler waits for in-flight handlers before it
  ## cancels them and reports the ctx as stuck. Returns as soon as they finish,
  ## so this only bounds a *stuck* handler. A `var` so tests can shorten it.

proc recycleContext[T](
    ctx: ptr FFIContext[T], ongoingProcessReq: ptr seq[Future[void]]
) {.async.} =
  ## Runs on the FFI thread. Drains in-flight handlers, frees the lib, clears the
  ## per-context event state, releases the slot for reuse, and fires the recycle
  ## callback. The worker threads (and their kqueue fds) stay alive for reuse.
  ongoingProcessReq[].keepItIf(not it.finished())

  ## 1. Let in-flight handlers finish on their own, bounded by RecycleTimeout.
  var naturallyDrained = ongoingProcessReq[].len == 0
  if not naturallyDrained:
    naturallyDrained = await allFutures(ongoingProcessReq[]).withTimeout(RecycleTimeout)

  ## 2. If any are wedged, cancel them and give the cancellations a bounded moment.
  var safeToRecycle = naturallyDrained
  if not naturallyDrained:
    for fut in ongoingProcessReq[]:
      if not fut.finished():
        fut.cancelSoon()
    safeToRecycle = await allFutures(ongoingProcessReq[]).withTimeout(RecycleTimeout)

  let cb = ctx.recycleCallback
  let ud = ctx.recycleUserData
  ctx.recycleCallback = nil

  if safeToRecycle:
    freeLib(ctx)
    # Reset per-context event state so a reused slot starts clean: drop listeners
    # and drain/free any queued events so they aren't delivered to the next owner.
    removeAllEventListeners(ctx[].eventRegistry)
    while true:
      let opt = ctx.eventQueue.tryDequeueEvent()
      if opt.isNone():
        break
      let qe = opt.get()
      freeEventBuffers(qe.name, qe.data)
    ctx.eventQueueStuck.store(false)
    ongoingProcessReq[].setLen(0)
    ctx.release()

  if not cb.isNil():
    foreignThreadGc:
      let msg =
        if naturallyDrained:
          ""
        else:
          "recycle: in-flight requests did not finish in time"
      let cmsg = msg.cstring
      let retCode = if naturallyDrained: RET_OK else: RET_ERR
      cb(retCode, unsafeAddr cmsg[0], cast[csize_t](msg.len), ud)

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
      # A destructor requested recycle: drain + free + park this slot for reuse,
      # keeping the threads (and their kqueue fds) alive. Claim it atomically so
      # only this loop runs the recycle.
      var expectedRecycle = CtxLifecycle.RecyclePending
      if ctx.lifecycle.compareExchange(expectedRecycle, CtxLifecycle.Recycling):
        await recycleContext(ctx, addr pending)
        continue

      # Freezes if a sync handler blocks the dispatcher; event thread reads to detect wedged FFI thread.
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

    # Drain so each pending handler's deleteRequest defer runs before exit.
    reapCompleted()
    if pending.len > 0:
      try:
        await allFutures(pending)
      except CatchableError as e:
        error "draining pending FFI requests on shutdown raised", error = e.msg

  waitFor ffiRun(ctx)
