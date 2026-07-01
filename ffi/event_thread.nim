## Event-thread body and FFI-thread liveness monitoring.
##
## Included from `ffi_context.nim` — inherits its imports, FFIContext type,
## and the heartbeat-timing constants. Lives alongside `ffi_thread.nim`
## so each thread's machinery is readable on its own.
##
## Responsibilities:
## - Drain queued events into listener callbacks.
## - Watch `ctx.ffiHeartbeat` and emit `NotRespondingEvent` / `RespondingEvent`
##   on FFI-thread stall and recovery transitions.

type
  NotRespondingEvent* = object
  RespondingEvent* = object

const
  NotRespondingEventName* = "not_responding"
  RespondingEventName* = "responding"

proc dispatchToListeners[T](
    ctx: ptr FFIContext[T], eventName: string, data: pointer, dataLen: int
) =
  ## Holds reg.lock for the entire snapshot + invocation so concurrent
  ## add/remove on this registry blocks until dispatch returns.
  withLock ctx[].eventRegistry.lock:
    let listeners = ctx[].eventRegistry.byEvent.getOrDefault(eventName)
    if listeners.len == 0:
      chronicles.debug "no listener registered", event = eventName
      return
    foreignThreadGc:
      try:
        notifyListeners(listeners, RET_OK, data, dataLen)
      except Exception, CatchableError:
        notifyListenersErr(
          listeners,
          "Exception dispatching " & eventName & ": " & getCurrentExceptionMsg(),
        )

proc emitLivenessEvent[T, P](ctx: ptr FFIContext[T], name: string, payload: P) =
  ## Encodes a liveness event and dispatches directly to listeners (bypassing
  ## the queue, which may be wedged). Runs on the event thread.
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

proc onNotResponding*(ctx: ptr FFIContext) =
  emitLivenessEvent(ctx, NotRespondingEventName, NotRespondingEvent())

proc onResponding*(ctx: ptr FFIContext) =
  ## Fired once when the heartbeat resumes after a NotRespondingEvent.
  ## Lets consumers clear any "library hung" UI state without polling.
  emitLivenessEvent(ctx, RespondingEventName, RespondingEvent())

proc dispatchQueuedEvent[T](ctx: ptr FFIContext[T], qe: QueuedEvent) =
  ## Reads the borrowed slab payload; `commitDequeue` (not this proc) frees any
  ## heap-fallback buffer once the read has returned.
  ctx.dispatchToListeners($qe.name, qe.data, qe.dataLen)

proc drainOneEvent[T](ctx: ptr FFIContext[T]): bool =
  ## Peek → dispatch → commit for a single event. The slot stays pinned across
  ## dispatch so the producer can't reuse its slab buffer mid-read; `defer`
  ## commits even if a listener raises. Returns false when the queue is empty.
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
  ## Fires onNotResponding / onResponding on heartbeat stall / recovery.
  ## Both transitions latch — each fires at most once per stall episode.
  if Moment.now() - hb.startedAt <= FFIHeartbeatStartDelay:
    return
  let cur = ctx.ffiHeartbeat.load()
  if cur != hb.lastValue:
    if hb.notifiedStale:
      onResponding(ctx)
    hb.lastValue = cur
    hb.lastChange = Moment.now()
    hb.notifiedStale = false
  elif not hb.notifiedStale and Moment.now() - hb.lastChange > FFIHeartbeatStaleThreshold:
    onNotResponding(ctx)
    hb.notifiedStale = true

proc eventRun[T](ctx: ptr FFIContext[T]) {.async.} =
  var hb = HeartbeatMonitor.init(ctx)
  var notifiedStuck = false # latched forever — eventQueueStuck is sticky terminal.

  while ctx.running.load():
    # Wake on enqueue or tick — whichever first.
    discard await ctx.eventQueueSignal.wait().withTimeout(EventThreadTickInterval)

    ctx.drainEventQueue()

    # Fire after drain so reg.lock is free — FFI-thread would deadlock here.
    if not notifiedStuck and ctx.eventQueueStuck.load():
      onNotResponding(ctx)
      notifiedStuck = true

    if not ctx.running.load():
      break
    hb.check(ctx)

proc eventThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## Drains the event queue and runs the FFI-thread heartbeat check.
  ## Borrows each queued slab payload until dispatch returns, then releases
  ## any heap-fallback buffer.
  defer:
    let fireRes = ctx.eventThreadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire eventThreadExitSignal", err = fireRes.error

  try:
    waitFor eventRun(ctx)
  except CatchableError as e:
    error "event thread exited with exception", error = e.msg
