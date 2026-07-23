import std/[atomics, sysatomics]
import results
import ./ffi_context

const MaxFFIContexts* = 32

type
  StaticCtxState = enum
    ## Lifecycle of the pool's `{.ffiStatic.}` context; see `staticFFIContext`.
    StaticCtxNone
    StaticCtxCreating
    StaticCtxDestroying
    StaticCtxReady

  FFIContextPool*[T] = object
    ## Fixed pool of FFI contexts, plus the one `{.ffiStatic.}` context.
    # Each live context holds 5 ThreadSignalPtrs — one fd each on Linux, two (a
    # socketpair) elsewhere. Under refc a destroyed context cannot close them
    # (see `deinitContextResources`), so churn leaks fds unbounded.
    slots: array[MaxFFIContexts, FFIContext[T]]
    inUse: array[MaxFFIContexts, Atomic[bool]]
    staticCtx: Atomic[pointer]
    staticState: Atomic[StaticCtxState]

proc acquireSlot[T](pool: var FFIContextPool[T]): Result[ptr FFIContext[T], string] =
  for i in 0 ..< MaxFFIContexts:
    var expected = false
    if pool.inUse[i].compareExchange(expected, true):
      return ok(pool.slots[i].addr)
  err("FFI context pool exhausted (max " & $MaxFFIContexts & " contexts)")

proc releaseSlot[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]) =
  for i in 0 ..< MaxFFIContexts:
    if pool.slots[i].addr == ctx:
      pool.inUse[i].store(false)
      return

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  let ctx = pool.acquireSlot().valueOr:
    return err("createFFIContext: acquireSlot failed: " & $error)
  initContextResources(ctx).isOkOr:
    pool.releaseSlot(ctx)
    return err("createFFIContext: initContextResources failed: " & $error)
  ok(ctx)

proc isStaticCtx[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]): bool =
  ## True while `ctx` is the pool's static context, including mid-teardown.
  # `staticCtx` is cleared only once the slot is released, so matching on the
  # pointer covers `Destroying` too.
  pool.staticCtx.load() == cast[pointer](ctx)

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## On thread-exit timeout the slot is leaked; closing live-thread resources is unsafe.
  # Destroying it would release the slot while `staticState` still points at it.
  if pool.isStaticCtx(ctx):
    return err("destroyFFIContext(pool): the {.ffiStatic.} context outlives every ctx")
  ctx.stopAndJoinThreads().isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  # Required: next acquisition would otherwise re-init a live lock (UB).
  let deinitRes = ctx.deinitContextResources()
  pool.releaseSlot(ctx)
  deinitRes.isOkOr:
    return err("destroyFFIContext(pool): " & $error)
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
  ctx.stopAndJoinThreads().isOkOr:
    # Threads are still live: leak the slot rather than free resources under them.
    pool.staticState.store(StaticCtxReady)
    return err("destroyStaticFFIContext: " & $error)
  let deinitRes = ctx.deinitContextResources()
  pool.releaseSlot(ctx)
  pool.staticCtx.store(nil)
  pool.staticState.store(StaticCtxNone)
  deinitRes.isOkOr:
    return err("destroyStaticFFIContext: " & $error)
  ok()

proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## Rejects nil / dangling pointers at the API boundary.
  if ctx.isNil():
    return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.slots[i].addr) == ctx:
      return pool.inUse[i].load()
  false
