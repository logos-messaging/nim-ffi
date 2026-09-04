import std/[atomics, sysatomics]
import chronicles, results
import ./ffi_context

const MaxFFIContexts* = 32

const
  SlotBits = 5
  SlotMask = (1'u shl SlotBits) - 1

static:
  doAssert MaxFFIContexts <= int(SlotMask) + 1,
    "SlotBits is too small for MaxFFIContexts"

proc makeToken(slot: int, generation: uint): FFICtxToken =
  ## Host handle: the generation of the claim above the slot index. A claim makes the generation odd and non-zero, so a nil token never resolves.
  cast[FFICtxToken]((generation shl SlotBits) or (uint(slot) and SlotMask))

func tokenGeneration*(token: FFICtxToken): uint =
  ## The claim a token was issued under: odd by construction, and 0 for a nil token.
  cast[uint](token) shr SlotBits

type
  StaticCtxState = enum
    ## Lifecycle of the pool's `{.ffiStatic.}` context; see `staticFFIContext`.
    StaticCtxNone
    StaticCtxCreating
    StaticCtxDestroying
    StaticCtxReady

  FFIContextPool*[T] = object
    ## Fixed pool, plus the one `{.ffiStatic.}` context. A slot's resources outlive its cycles.
    contexts: array[MaxFFIContexts, FFIContext[T]]
    initialized: array[MaxFFIContexts, Atomic[bool]]
    threadsUp: array[MaxFFIContexts, Atomic[bool]]
    staticCtx: Atomic[pointer]
    staticState: Atomic[StaticCtxState]

func slotIndex[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]): int =
  for i in 0 ..< MaxFFIContexts:
    if pool.contexts[i].addr == ctx:
      return i
  -1

proc releaseSlot[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]) =
  ## Hands the slot back with its resources intact; only `destroyFFIContext` rebuilds one.

  # The join is the one exit from quarantine: the orphans died with the thread. Clear here so `quarantinedSlots` does not count a freed slot.
  ctx.lifecycle.store(CtxLifecycle.Active)
  ctx.recycleFailure.store(RecycleFailure.None)
  ctx.releaseClaim()

proc quarantinedSlots*[T](pool: var FFIContextPool[T]): int =
  ## Slots that a failed recycle took out of service; exact, because only a full destroy clears `RecycleFailed`.
  var count = 0
  for i in 0 ..< MaxFFIContexts:
    if pool.contexts[i].lifecycle.load() == CtxLifecycle.RecycleFailed:
      count.inc()
  count

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a context from the fixed pool. A slot's worker is built once on
  ## first use and reused (markAsActive) on every later acquisition.
  for i in 0 ..< MaxFFIContexts:
    let ctx = pool.contexts[i].addr
    if not ctx.tryClaim():
      continue
    ctx.token = makeToken(i, ctx.generation.load())
    if pool.initialized[i].load():
      # Reused slot: a prior recycle drained and released it, keeping its resources.
      ctx.markAsActive()
      if not pool.threadsUp[i].load():
        ctx.startContextThreads().isOkOr:
          ctx.releaseClaim()
          return err("createFFIContext: startContextThreads failed: " & $error)
        pool.threadsUp[i].store(true)
      return ok(ctx)
    initContextResources(ctx).isOkOr:
      ctx.releaseClaim()
      return err("createFFIContext: initContextResources failed: " & $error)
    pool.initialized[i].store(true)
    pool.threadsUp[i].store(true)
    return ok(ctx)
  let quarantined = pool.quarantinedSlots()
  if quarantined > 0:
    # Name the lost capacity: from the outside it looks like a plain leak.
    error "FFI context pool exhausted; a {.ffiDtor.} that does not finish costs " &
      "a slot for the life of the process",
      quarantined = quarantined, max = MaxFFIContexts
  err(
    "FFI context pool exhausted (max " & $MaxFFIContexts & " contexts, " & $quarantined &
      " quarantined by a failed teardown)"
  )

proc isStaticCtx[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]): bool =
  ## True while `ctx` is the pool's static context, including mid-teardown.
  # `staticCtx` is cleared only once the slot is released, so matching on the
  # pointer covers `Destroying` too.
  pool.staticCtx.load() == cast[pointer](ctx)

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Full teardown, for a slot rebuilt from scratch; normal cleanup uses recycleFFIContext.
  if ctx.isNil():
    return err("destroyFFIContext(pool): no context (nil)")
  # Destroying it would release the slot while `staticState` still points at it.
  if pool.isStaticCtx(ctx):
    return err("destroyFFIContext(pool): the {.ffiStatic.} context outlives every ctx")
  ctx.stopAndJoinThreads().isOkOr:
    error "context threads did not exit; the pool slot and its resources leak " &
      "(a free under live threads is unsafe)", reason = error
    return err("destroyFFIContext(pool): " & $error)
  let slot = pool.slotIndex(ctx)
  if slot >= 0:
    pool.threadsUp[slot].store(false)
    pool.initialized[slot].store(false)
  let deinitRes = ctx.deinitContextResources()
  pool.releaseSlot(ctx)
  deinitRes.isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  ok()

proc parkSlotThreads[T](
    pool: var FFIContextPool[T], slot: int, timeout = ThreadExitTimeout
): Result[void, string] =
  ## Joins the slot's thread pair, keeping its resources: those heaps belong to the exiting threads.
  if slot < 0 or slot >= MaxFFIContexts:
    return err("parkSlotThreads: slot " & $slot & " is not a pool slot")
  ?pool.contexts[slot].addr.stopAndJoinThreads(timeout)
  pool.threadsUp[slot].store(false)
  ok()

proc hasLiveContext[T](pool: var FFIContextPool[T]): bool =
  ## A slot a host still owns. Skips the static and quarantined ones: those never come free.
  for i in 0 ..< MaxFFIContexts:
    let ctx = pool.contexts[i].addr
    if not ctx.isInUse():
      continue
    if pool.isStaticCtx(ctx):
      continue
    if ctx.lifecycle.load() == CtxLifecycle.RecycleFailed:
      continue
    return true
  false

proc parkIdleSlots[T](pool: var FFIContextPool[T]) =
  ## Stops and joins the threads of every free slot.
  for i in 0 ..< MaxFFIContexts:
    let ctx = pool.contexts[i].addr
    if not pool.threadsUp[i].load():
      continue
    # The claim is the lock: a slot another thread just took is not idle.
    if not ctx.tryClaim():
      continue
    pool.parkSlotThreads(i).isOkOr:
      # Keep the claim: a slot whose threads did not exit must not serve again.
      error "parking an idle context failed; its slot and threads leak", reason = error
      continue
    ctx.releaseClaim()

proc reapIfIdle[T](pool: var FFIContextPool[T]) =
  ## The exit policy: no context live, no thread of ours for the C runtime to finalize under.
  if onFFIThread or onEventThread:
    debug "skipping the idle reap: a destroy from inside the library's own " &
      "threads would join a thread to itself"
    return
  if pool.hasLiveContext():
    return
  pool.parkIdleSlots()

proc recycleFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Normal teardown. The slot's threads stay up unless this was the last live context.

  # `resolveCtx` answers nil for a stale token, and its result lands here.
  if ctx.isNil():
    return err("recycleFFIContext(pool): no context (nil)")
  # Recycling it would release the slot while `staticState` still points at it.
  if pool.isStaticCtx(ctx):
    return err("recycleFFIContext(pool): the {.ffiStatic.} context outlives every ctx")
  ?ctx.requestRecycle()

  pool.reapIfIdle()
  ok()

proc staticFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## The pool's `{.ffiStatic.}` context, created on first use: a static proc has
  ## no ctx of its own, but its handler still needs an FFI thread.
  # Holds its slot until `destroyStaticFFIContext`, so `pool` must outlive its
  # threads: only call this on the global `declareLibrary` emits. `myLib` stays
  # the zero value. A failed create resets to `StaticCtxNone` so waiters retry.
  while true:
    case pool.staticState.load()
    of StaticCtxReady:
      return ok(cast[ptr FFIContext[T]](pool.staticCtx.load()))
    of StaticCtxCreating, StaticCtxDestroying:
      cpuRelax()
    of StaticCtxNone:
      var expected = StaticCtxNone
      if not pool.staticState.compareExchange(expected, StaticCtxCreating):
        continue
      let ctx = pool.createFFIContext().valueOr:
        pool.staticState.store(StaticCtxNone)
        return err("staticFFIContext: " & error)
      pool.staticCtx.store(cast[pointer](ctx))
      pool.staticState.store(StaticCtxReady)
      return ok(ctx)

proc destroyStaticFFIContext*[T](pool: var FFIContextPool[T]): Result[void, string] =
  ## Teardown counterpart to `staticFFIContext`: stops the static context's
  ## threads and frees its slot. A no-op when there is no static context.
  # Claiming `Ready -> Destroying` serialises concurrent teardowns; it does not
  # make teardown safe against a static call already in flight.
  var expected = StaticCtxReady
  if not pool.staticState.compareExchange(expected, StaticCtxDestroying):
    return ok()
  let ctx = cast[ptr FFIContext[T]](pool.staticCtx.load())
  let slot = pool.slotIndex(ctx)
  if slot < 0:
    pool.staticState.store(StaticCtxReady)
    return err("destroyStaticFFIContext: the static context is not a pool slot")
  pool.parkSlotThreads(slot).isOkOr:
    # Threads are still live: leak the slot rather than hand it back under them.
    pool.staticState.store(StaticCtxReady)
    error "the {.ffiStatic.} context's threads did not exit; its slot and " &
      "resources leak", reason = error
    return err("destroyStaticFFIContext: " & $error)
  pool.releaseSlot(ctx)
  pool.staticCtx.store(nil)
  pool.staticState.store(StaticCtxNone)
  ok()

proc shutdownFFIContextPool*[T](pool: var FFIContextPool[T]): Result[void, string] =
  ## Joins every slot's threads. An owned slot runs its `{.ffiDtor.}`, then is quarantined.
  var firstErr = ""
  pool.destroyStaticFFIContext().isOkOr:
    firstErr = error

  for i in 0 ..< MaxFFIContexts:
    if not pool.threadsUp[i].load():
      continue
    let ctx = pool.contexts[i].addr
    # Retire the claim first: a submit that lands after the worker's last drain is never answered.
    if ctx.isInUse():
      ctx.lifecycle.store(CtxLifecycle.RecycleFailed)
    pool.parkSlotThreads(i, OwnedExitTimeout).isOkOr:
      if firstErr.len == 0:
        firstErr = error
      continue
    # A create that raced the park must not keep an Active context with dead threads.
    if ctx.isInUse():
      ctx.lifecycle.store(CtxLifecycle.RecycleFailed)
      error "a context was still claimed at shutdown; its slot is quarantined " &
        "and its calls now fail instead of queueing to a dead thread"

  if firstErr.len > 0:
    return err("shutdownFFIContextPool: " & firstErr)
  ok()

proc resolveCtx*[T](
    pool: var FFIContextPool[T], token: FFICtxToken
): ptr FFIContext[T] =
  ## The context a host token names, or nil when the token is nil, forged, or
  ## issued for an earlier owner of the slot.
  let generation = token.tokenGeneration()
  if generation == 0:
    return nil
  # An issued generation is odd, so matching it also proves the slot is claimed.
  let ctx = pool.contexts[int(cast[uint](token) and SlotMask)].addr
  if ctx.generation.load() != generation:
    return nil
  ctx

proc isValidCtx*[T](pool: var FFIContextPool[T], token: FFICtxToken): bool =
  ## Rejects a nil, forged or stale token at the API boundary.
  not pool.resolveCtx(token).isNil()
