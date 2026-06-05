import std/atomics
import results
import ./ffi_context, ./ffi_types

const MaxFFIContexts* = 32
  ## Maximum number of concurrently live FFI contexts when using FFIContextPool.
  ## Fds and threads are only consumed for slots that are actually acquired,
  ## so this value only affects the upfront memory of the pool array.

type FFIContextPool*[T] = object
  ## Fixed-size pool of FFI contexts. Avoids dynamic heap allocation per context
  ## and bounds the total number of file descriptors consumed by ThreadSignalPtrs
  ## to at most MaxFFIContexts * 2.
  slots: array[MaxFFIContexts, FFIContext[T]]
  initialized: array[MaxFFIContexts, Atomic[bool]]
    ## Whether a slot's worker (threads, chronos dispatcher and ThreadSignalPtrs)
    ## has been built. Set on first acquisition and kept set across park/reuse,
    ## so a reacquired slot reuses the same fds instead of allocating a fresh set
    ## every create/destroy cycle. Cleared only by full teardown.

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a slot from the fixed pool. The slot's worker is built once on
  ## first use and REUSED on every later acquisition of the same slot (a slot is
  ## made reacquirable by releaseFFIContext, which parks it without tearing the
  ## worker down). This is what keeps fd usage bounded: repeated create/destroy
  ## cycles no longer leak a fresh set of ThreadSignalPtr/dispatcher fds.
  for i in 0 ..< MaxFFIContexts:
    let ctx = pool.slots[i].addr
    if not ctx.tryClaim():
      continue
    if pool.initialized[i].load():
      ## Reused slot: a prior destroy drained and released it, worker still alive.
      ## Re-arm the gate and hand it back.
      ctx.markReacquired()
      return ok(ctx)
    initContextResources(ctx).isOkOr:
      ctx.unclaim()
      return err("createFFIContext: initContextResources failed: " & $error)
    pool.initialized[i].store(true)
    return ok(ctx)
  return err("FFI context pool exhausted (max " & $MaxFFIContexts & " contexts)")

proc releaseFFIContext*[T](
    ctx: ptr FFIContext[T], callback: FFICallBack, userData: pointer
): Result[void, string] =
  ## Parks a context for reuse without stopping its worker, so the next
  ## createFFIContext reuses the same threads and fds. Steady-state cleanup path
  ## for the generated destructor; destroyFFIContext is for failure/non-pool use.
  ##
  ## NON-BLOCKING: the FFI thread drains the handlers, frees the lib and releases
  ## the slot, then fires `callback` (RET_OK drained, RET_ERR stuck). The slot
  ## returns to the pool from that thread, so a reused slot never carries a straggler.
  return ctx.requestRecycle(callback, userData)

proc destroyFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Full teardown: stops/joins the worker threads and returns the slot to the
  ## pool, marking it uninitialised so a later createFFIContext rebuilds it. Used
  ## on creation failure and by non-pooling callers; steady-state cleanup should
  ## use releaseFFIContext to keep fd usage bounded. If the FFI thread is blocked
  ## and does not exit in time, the slot is leaked rather than reclaimed —
  ## closing its resources while the thread is still live would be unsafe.
  ctx.stopAndJoinThreads().isOkOr:
    return err("destroyFFIContext(pool): " & $error)
  for i in 0 ..< MaxFFIContexts:
    if pool.slots[i].addr == ctx:
      pool.initialized[i].store(false)
      break
  ctx.unclaim()
  return ok()

proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## Returns true only if ctx points to one of the pool's slots that is
  ## currently in use. Rejects nil, offset-invalid, and dangling pointers
  ## at the API boundary, preventing use-after-free dereferences.
  if ctx.isNil():
    return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.slots[i].addr) == ctx:
      return cast[ptr FFIContext[T]](ctx).isClaimed()
  return false
