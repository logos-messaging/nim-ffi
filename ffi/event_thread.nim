## Event-thread body and FFI-thread liveness monitoring.
##
## Included from `ffi_context.nim` — inherits its imports, FFIContext type,
## and the heartbeat-timing constants. Lives alongside `ffi_thread.nim`
## so each thread's machinery is readable on its own.
##
## Responsibilities:
## - Drain queued events into listener callbacks (queue producer lands in PR #69).
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
  ## Encodes a zero-field liveness event (`NotRespondingEvent`,
  ## `RespondingEvent`) and dispatches it directly to listeners, bypassing
  ## the event queue (which may itself be wedged). Runs on the event thread.
  let event =
    try:
      EventEnvelope[P](eventType: name, payload: payload).cborEncode()
    except CatchableError as exc:
      chronicles.error "liveness event encode failed", name = name, err = exc.msg
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
  ## Fired once when the FFI thread's heartbeat starts advancing again
  ## after a `NotRespondingEvent`. Lets consumers clear any "library
  ## hung" UI state without polling.
  emitLivenessEvent(ctx, RespondingEventName, RespondingEvent())

proc dispatchQueuedEvent[T](ctx: ptr FFIContext[T], qe: QueuedEvent) =
  ## Frees `qe`'s c_malloc buffers on exit.
  defer:
    if not qe.name.isNil():
      c_free(cast[pointer](qe.name))
    if not qe.data.isNil():
      c_free(qe.data)
  ctx.dispatchToListeners($qe.name, qe.data, qe.dataLen)

proc drainEventQueue[T](ctx: ptr FFIContext[T]) =
  while true:
    let opt = ctx.eventQueue.tryDequeueEvent()
    if opt.isNone():
      break
    ctx.dispatchQueuedEvent(opt.get())

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
  ## Fires `onNotResponding` once the FFI thread's heartbeat counter stops
  ## advancing past the stale threshold, and fires `onResponding` once it
  ## starts advancing again. Both transitions latch so each is emitted at
  ## most once per stall episode.
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

  while ctx.running.load():
    # Wake on enqueue or tick — whichever first. The enqueue path lands in PR #69;
    # until then the wait always times out and we fall through to the heartbeat check.
    discard await ctx.eventQueueSignal.wait().withTimeout(EventThreadTickInterval)

    ctx.drainEventQueue()

    if not ctx.running.load():
      break
    hb.check(ctx)

proc eventThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## Drains the event queue and runs the FFI-thread heartbeat check.
  ## Owns the queued `c_malloc` payloads until dispatch returns.
  defer:
    let fireRes = ctx.eventThreadExitSignal.fireSync()
    if fireRes.isErr():
      error "failed to fire eventThreadExitSignal", err = fireRes.error

  try:
    waitFor eventRun(ctx)
  except CatchableError as exc:
    error "event thread exited with exception", error = exc.msg
