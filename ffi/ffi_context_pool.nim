import std/atomics
import results
import ./ffi_context

const MaxFFIContexts* = 32
  ## Maximum number of concurrently live FFI contexts when using FFIContextPool.
  ## Fds and threads are only consumed for slots that are actually acquired,
  ## so this value only affects the upfront memory of the pool array.

type FFIContextPool*[T] = object
  ## Fixed-size pool of FFI contexts. Avoids dynamic heap allocation per context
  ## and bounds the total number of file descriptors consumed by ThreadSignalPtrs
  ## to at most MaxFFIContexts * 2.
  slots: array[MaxFFIContexts, FFIContext[T]]
  inUse: array[MaxFFIContexts, Atomic[bool]]

proc acquireSlot[T](pool: var FFIContextPool[T]): Result[ptr FFIContext[T], string] =
  for i in 0 ..< MaxFFIContexts:
    var expected = false
    if pool.inUse[i].compareExchange(expected, true):
      return ok(pool.slots[i].addr)
  return err("FFI context pool exhausted (max " & $MaxFFIContexts & " contexts)")

proc releaseSlot[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]) =
  for i in 0 ..< MaxFFIContexts:
    if pool.slots[i].addr == ctx:
      pool.inUse[i].store(false)
      return

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a slot from the fixed pool and initialises it as an FFI context.
  ## Bounded fd usage: at most MaxFFIContexts * 2 ThreadSignalPtr fds are ever open.
  let ctx = pool.acquireSlot().valueOr:
    return err("createFFIContext: acquireSlot failed: " & $error)
  initContextResources(ctx).isOkOr:
    pool.releaseSlot(ctx)
    return err("createFFIContext: initContextResources failed: " & $error)
  return ok(ctx)

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Stops the FFI context and returns its slot to the pool. If the FFI thread
  ## is blocked and does not exit in time, the slot is leaked rather than
  ## reclaimed — closing its resources while the thread is still live would be
  ## unsafe.
  ctx.stopAndJoinThreads().isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  pool.releaseSlot(ctx)
  return ok()

proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## Returns true only if ctx points to one of the pool's slots that is
  ## currently in use. Rejects nil, offset-invalid, and dangling pointers
  ## at the API boundary, preventing use-after-free dereferences.
  if ctx.isNil():
    return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.slots[i].addr) == ctx:
      return pool.inUse[i].load()
  return false
