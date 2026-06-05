import std/atomics
import results
import ./ffi_context

const MaxFFIContexts* = 32
  # Only affects upfront pool memory; fds/threads consumed per acquired slot.

type FFIContextPool*[T] = object
  ## Fixed pool. Bounds ThreadSignalPtr fds at MaxFFIContexts * 2.
  slots: array[MaxFFIContexts, FFIContext[T]]
  inUse: array[MaxFFIContexts, Atomic[bool]]

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

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## On thread-exit timeout the slot is leaked — closing live-thread resources is unsafe.
  ctx.stopAndJoinThreads().isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  # Required: next acquisition would otherwise re-init a live lock (UB).
  let deinitRes = ctx.deinitContextResources()
  pool.releaseSlot(ctx)
  deinitRes.isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  ok()

proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## Rejects nil / offset-invalid / dangling pointers at the API boundary.
  if ctx.isNil():
    return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.slots[i].addr) == ctx:
      return pool.inUse[i].load()
  false
