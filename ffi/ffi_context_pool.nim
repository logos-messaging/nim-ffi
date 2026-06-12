import std/atomics
import results
import ./ffi_context, ./ffi_types

const MaxFFIContexts* = 32
  ## Maximum number of concurrently live FFI contexts when using FFIContextPool.
  ## Each slot's threads, signals and dispatcher kqueue fds are created once and
  ## reused, so this also caps the process's steady-state fd usage.

type FFIContextPool*[T] = object
  contexts: array[MaxFFIContexts, FFIContext[T]]
  initialized: array[MaxFFIContexts, Atomic[bool]]
    ## Whether the slot's worker has been built. Once true it stays true for the
    ## process lifetime — destroy recycles the context rather than tearing it down.

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a context from the fixed pool. The worker (threads + signals +
  ## dispatcher kqueues) is built once on first use and REUSED on every later
  ## acquisition — chronos never frees a dispatcher's kqueue fd, so a
  ## thread-per-context model would leak fds unboundedly.
  for i in 0 ..< MaxFFIContexts:
    let ctx = pool.contexts[i].addr
    if not ctx.tryClaim():
      continue
    if pool.initialized[i].load():
      ## Reused slot: a prior destroy drained and parked it; worker still alive.
      ctx.markAsActive()
      return ok(ctx)
    initContextResources(ctx).isOkOr:
      ctx.release()
      return err("createFFIContext: initContextResources failed: " & $error)
    pool.initialized[i].store(true)
    return ok(ctx)
  return err("FFI context pool exhausted (max " & $MaxFFIContexts & " contexts)")

proc releaseFFIContext*[T](
    ctx: ptr FFIContext[T], callback: FFICallBack, userData: pointer
): Result[void, string] =
  ## Recycle/park the context for reuse without stopping its worker threads.
  ## `callback` fires once the FFI thread has drained and parked it.
  ctx.requestRecycle(callback, userData)

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Full teardown: stops/joins the worker threads and returns the context to the
  ## pool, marking it uninitialised so a later createFFIContext rebuilds it. Only
  ## for process/pool shutdown — normal destruction uses releaseFFIContext.
  ctx.stopAndJoinThreads().isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  for i in 0 ..< MaxFFIContexts:
    if pool.contexts[i].addr == ctx:
      pool.initialized[i].store(false)
      break
  ctx.release()
  return ok()

proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## True only if ctx points to one of the pool's contexts that is currently
  ## claimed (in use). Rejects nil / dangling / parked contexts at the API boundary.
  if ctx.isNil():
    return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.contexts[i].addr) == ctx:
      return cast[ptr FFIContext[T]](ctx).isInUse()
  return false
