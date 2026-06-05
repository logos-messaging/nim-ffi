import std/atomics
import results
import ./ffi_context, ./ffi_types

const MaxFFIContexts* = 32
  ## Maximum number of concurrently live FFI contexts when using FFIContextPool.

type FFIContextPool*[T] = object
  contexts: array[MaxFFIContexts, FFIContext[T]]
  initialized: array[MaxFFIContexts, Atomic[bool]]

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a context from the fixed pool. The context's worker is built once on
  ## first use and reused on every later acquisition.

  for i in 0 ..< MaxFFIContexts:
    let ctx = pool.contexts[i].addr
    if not ctx.tryClaim():
      continue
    if pool.initialized[i].load():
      ## Reused context: a prior destroy drained and released it, worker still alive.
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
  return ctx.requestRecycle(callback, userData)

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Full teardown: stops/joins the worker threads and returns the context to the
  ## pool, marking it uninitialised so a later createFFIContext rebuilds it.
  ctx.stopAndJoinThreads().isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  for i in 0 ..< MaxFFIContexts:
    if pool.contexts[i].addr == ctx:
      pool.initialized[i].store(false)
      break
  ctx.release()
  return ok()

proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## Returns true only if ctx points to one of the pool's contexts that is
  ## currently in use.
  if ctx.isNil():
    return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.contexts[i].addr) == ctx:
      return cast[ptr FFIContext[T]](ctx).isInUse()
  return false
