## Event-thread body and FFI-thread liveness monitoring. Included from
## `ffi_context.nim`. Drains queued events into listeners and emits
## NotResponding/Responding on FFI-heartbeat stall/recovery.

type
  NotRespondingReason* {.pure.} = enum
    heartbeat ## FFI thread stalled; recreate the context
    queueFull ## sustained event-queue overflow; recovers on its own

  NotRespondingEvent* = object
    reason*: NotRespondingReason

  RespondingEvent* = object
    reason*: NotRespondingReason

const
  NotRespondingEventName* = "not_responding"
  RespondingEventName* = "responding"

proc dispatchToListeners[T](
    ctx: ptr FFIContext[T], eventName: string, data: pointer, dataLen: int
) =
  ## Calls the listeners off a snapshot with reg.lock released, so a listener may
  ## mutate the registry. A remove from another thread waits the delivery out.
  let listeners = ctx[].eventRegistry.beginDispatch(eventName)
  defer:
    ctx[].eventRegistry.endDispatch()
  if listeners.len == 0:
    chronicles.debug "no listener registered", event = eventName
    return
  foreignThreadGc:
    try:
      ctx[].eventRegistry.notifyListeners(eventName, listeners, RET_OK, data, dataLen)
    except Exception, CatchableError:
      ctx[].eventRegistry.notifyListenersErr(
        eventName,
        listeners,
        "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg(),
      )

proc emitLivenessEvent[T, P](ctx: ptr FFIContext[T], name: string, payload: P) =
  ## Dispatches directly to listeners, bypassing the (possibly wedged) queue.
  let event =
    try:
      EventEnvelope[P](eventType: name, payload: payload).cborEncode()
    except CatchableError as e:
      chronicles.error "liveness event encode failed", name = name, err = e.msg
      return
  let dataPtr: pointer =
    if event.len > 0:
      cast[pointer](unsafeAddr event[0])
    else:
      cast[pointer](emptyListenerPayload)
  ctx.dispatchToListeners(name, dataPtr, event.len)

proc onNotResponding*(ctx: ptr FFIContext, reason: NotRespondingReason) =
  emitLivenessEvent(ctx, NotRespondingEventName, NotRespondingEvent(reason: reason))

proc onResponding*(ctx: ptr FFIContext, reason: NotRespondingReason) =
  ## Fired once when `reason` ends. Another reason may still be active.
  emitLivenessEvent(ctx, RespondingEventName, RespondingEvent(reason: reason))

type
  ReverseWorkerBlockedEvent* = object
    worker*: int
    callId*: uint64
    procName*: string ## the reverse proc the worker is stuck in
    elapsedMs*: int64 ## time spent in it so far

  ReverseWorkerRecoveredEvent* = object
    worker*: int

proc checkReverseWorkers[T](ctx: ptr FFIContext[T]) =
  for t in ctx[].reverse.scanReverseWorkers(int64(ReverseWorkerStallMs) * 1_000_000'i64):
    if t.blocked:
      emitLivenessEvent(
        ctx,
        ReverseWorkerBlockedEventName,
        ReverseWorkerBlockedEvent(
          worker: t.idx, callId: t.callId, procName: t.procName, elapsedMs: t.elapsedMs
        ),
      )
    else:
      emitLivenessEvent(
        ctx, ReverseWorkerRecoveredEventName, ReverseWorkerRecoveredEvent(worker: t.idx)
      )

proc dispatchQueuedEvent[T](ctx: ptr FFIContext[T], qe: QueuedEvent) =
  ## Reads the borrowed slab payload; `commitDequeue` frees any heap fallback.
  ctx.dispatchToListeners($qe.name, qe.data, qe.dataLen)

proc drainOneEvent[T](ctx: ptr FFIContext[T]): bool =
  ## Peek → dispatch → commit; slot stays pinned across dispatch, `defer` commits
  ## even if a listener raises. False when the queue is empty.
  let opt = ctx.eventQueue.peekEvent()
  if opt.isNone():
    return false
  defer:
    ctx.eventQueue.commitDequeue()
  ctx.dispatchQueuedEvent(opt.get())
  true

proc drainEventQueue[T](ctx: ptr FFIContext[T]) =
  while ctx.drainOneEvent():
    discard

static:
  doAssert EventOverflowSustainMs >= 4, "ffiEventOverflowSustainMs must be at least 4"

proc drainEventPass[T](ctx: ptr FFIContext[T]): bool =
  ## Drains up to one ring of events or one time budget, whichever ends first, so a slow listener cannot starve liveness.
  ## Returns true if eventQueue has events, false otherwise.
  const EventDrainPassBudget = chronos.milliseconds(EventOverflowSustainMs div 4)
  let deadline = Moment.now() + EventDrainPassBudget
  for _ in 0 ..< EventQueueCapacity:
    if not ctx.drainOneEvent():
      return false
    if Moment.now() >= deadline:
      break
  return ctx.eventQueue.hasEvents()

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
  ## Fires onNotResponding/onResponding on stall/recovery; each latches once per episode.
  if Moment.now() - hb.startedAt <= FFIHeartbeatStartDelay:
    return
  let cur = ctx.ffiHeartbeat.load()
  if cur != hb.lastValue:
    if hb.notifiedStale:
      onResponding(ctx, NotRespondingReason.heartbeat)
    hb.lastValue = cur
    hb.lastChange = Moment.now()
    hb.notifiedStale = false
  elif not hb.notifiedStale and Moment.now() - hb.lastChange > FFIHeartbeatStaleThreshold:
    onNotResponding(ctx, NotRespondingReason.heartbeat)
    hb.notifiedStale = true

proc eventRun[T](ctx: ptr FFIContext[T]) {.async.} =
  var hb = HeartbeatMonitor.init(ctx)
  var overflow = OverflowWatch()
  var overflowGen = ctx.currentGeneration()
  var ctxHasEvents = false

  # Keep draining after `running` flips false until the FFI thread exits, so events from an async {.ffiDtor.} teardown are still dispatched.
  while ctx.running.load() or not ctx.ffiThreadExited.load():
    if ctxHasEvents:
      # Yield once per pass so timers and other tasks on this loop still run under a backlog.
      await sleepAsync(chronos.milliseconds(0))
    else:
      discard await ctx.eventQueueSignal.wait().withTimeout(EventThreadTickInterval)

    ctxHasEvents = ctx.drainEventPass()

    # Liveness only while running; skip during the teardown drain.
    if ctx.running.load():
      if ctx.currentGeneration() != overflowGen:
        overflowGen = ctx.currentGeneration()
        overflow = OverflowWatch()
      # Fire after the drain so the notice does not queue behind a dispatch.
      let drops = ctx[].eventQueue.dropCounts().total()
      case overflow.step(drops, getMonoTime().ticks div 1_000_000)
      of OverflowChange.Sustained:
        onNotResponding(ctx, NotRespondingReason.queueFull)
      of OverflowChange.Cleared:
        onResponding(ctx, NotRespondingReason.queueFull)
      of OverflowChange.NoChange:
        discard
      # A recycle parks the loop in the teardown on purpose; a stall there is
      # not a fault, and clearListeners drops the onResponding that would follow.
      if ctx.lifecycle.load() == CtxLifecycle.Active:
        hb.check(ctx)
        ctx.checkReverseWorkers()

  # Catch anything enqueued between the last drain and the FFI thread's exit.
  ctx.drainEventQueue()

proc eventThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## Drains the event queue and runs the FFI-thread heartbeat check.
  registerCloseDispatcherHook()
  servedCtx = ctx

  defer:
    servedCtx = nil
    unregisterWaitedSignal(ctx.eventQueueSignal)
    let fireRes = ctx.eventThreadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire eventThreadExitSignal", err = fireRes.error

  try:
    waitFor eventRun(ctx)
  except CatchableError as e:
    error "event thread exited with exception", error = e.msg
