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
  initialized: array[MaxFFIContexts, Atomic[bool]]
    ## Whether a slot's worker (threads, chronos dispatcher and ThreadSignalPtrs)
    ## has been built. Set on first acquisition and kept set across park/reuse,
    ## so a reacquired slot reuses the same fds instead of allocating a fresh set
    ## every create/destroy cycle. Cleared only by full teardown.

proc releaseSlot[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]) =
  for i in 0 ..< MaxFFIContexts:
    if pool.slots[i].addr == ctx:
      pool.inUse[i].store(false)
      return

proc createFFIContext*[T](
    pool: var FFIContextPool[T]
): Result[ptr FFIContext[T], string] =
  ## Acquires a slot from the fixed pool. The slot's worker is built once on
  ## first use and REUSED on every later acquisition of the same slot (a slot is
  ## made reacquirable by releaseFFIContext, which parks it without tearing the
  ## worker down). This is what keeps fd usage bounded: repeated create/destroy
  ## cycles no longer leak a fresh set of ThreadSignalPtr/dispatcher fds.
  for i in 0 ..< MaxFFIContexts:
    var expected = false
    if not pool.inUse[i].compareExchange(expected, true):
      continue
    let ctx = pool.slots[i].addr
    if pool.initialized[i].load():
      ## Reused slot: worker threads, dispatcher and signals are already alive.
      return ok(ctx)
    initContextResources(ctx).isOkOr:
      pool.inUse[i].store(false)
      return err("createFFIContext: initContextResources failed: " & $error)
    pool.initialized[i].store(true)
    return ok(ctx)
  return err("FFI context pool exhausted (max " & $MaxFFIContexts & " contexts)")

proc releaseFFIContext*[T](
    pool: var FFIContextPool[T], ctx: ptr FFIContext[T]
): Result[void, string] =
  ## Parks a context for reuse: returns its slot to the pool WITHOUT stopping the
  ## worker threads, so the next createFFIContext reuses the same fds. This is the
  ## steady-state cleanup path, called by the generated destructor (ffiDtor);
  ## destroyFFIContext is only for creation failure and non-pooling callers.
  ##
  ## Runs on the CALLER's thread, not the FFI worker thread, and does NOT itself
  ## wait for in-flight work to finish. It is safe to park here because the
  ## framework processes one request at a time (see sendRequestToFFIThread): by
  ## the time the destructor calls this, the worker has finished the previous
  ## request and is idle (looping on reqSignal), so there is no handler still
  ## touching the slot when it is reused.
  ##
  ## Clearing callbackState removes the stored C event callback. The
  ## worker/watchdog threads stay alive after parking, so an event could still
  ## fire on this slot; with no callback set that event does nothing, instead of
  ## calling back into a consumer that has already released the context (whose
  ## user-data pointer may now be freed).
  ctx.callbackState = default(FFICallbackState)
  ctx.myLib = nil
  pool.releaseSlot(ctx)
  return ok()

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
