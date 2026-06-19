import std/atomics
import results
import ./ffi_context

const MaxFFIContexts* = 32
  # Only affects upfront pool memory; fds/threads consumed per acquired slot.

type FFIContextPool*[T] = object
  ## Fixed pool. Each slot's worker + event threads and signal fds are built
  ## once (on first use) and reused across create/recycle cycles — recycle keeps
  ## them alive, so repeated create/destroy does not churn fds. Bounds
  ## ThreadSignalPtr fds at MaxFFIContexts * (signals per ctx).
  contexts: array[MaxFFIContexts, FFIContext[T]]
  initialized: array[MaxFFIContexts, Atomic[bool]]

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a context from the fixed pool. A slot's worker is built once on
  ## first use and reused (markAsActive) on every later acquisition.
  for i in 0 ..< MaxFFIContexts:
    let ctx = pool.contexts[i].addr
    if not ctx.tryClaim():
      continue
    if pool.initialized[i].load():
      # Reused slot: a prior recycle drained and released it; worker still alive.
      ctx.markAsActive()
      return ok(ctx)
    initContextResources(ctx).isOkOr:
      ctx.release()
      return err("createFFIContext: initContextResources failed: " & $error)
    pool.initialized[i].store(true)
    return ok(ctx)
  err("FFI context pool exhausted (max " & $MaxFFIContexts & " contexts)")

proc recycleFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Normal teardown: drains in-flight handlers, frees the lib and returns the
  ## slot to the pool WITHOUT stopping its threads, so a later createFFIContext
  ## reuses them. Synchronous (waits for the FFI thread to finish draining).
  ctx.requestRecycle()

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Full teardown: stops/joins the worker + event threads and frees resources,
  ## marking the slot uninitialised so a later createFFIContext rebuilds it.
  ## Used for process-level shutdown; normal cleanup uses recycleFFIContext.
  ctx.stopAndJoinThreads().isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  let deinitRes = ctx.deinitContextResources()
  for i in 0 ..< MaxFFIContexts:
    if pool.contexts[i].addr == ctx:
      pool.initialized[i].store(false)
      break
  ctx.release()
  deinitRes.isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  ok()

proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## Rejects nil / offset-invalid / dangling pointers at the API boundary.
  if ctx.isNil():
    return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.contexts[i].addr) == ctx:
      return cast[ptr FFIContext[T]](ctx).isInUse()
  false
