## FFIContext type plus lifecycle (init / signal-stop / join / destroy).

{.passc: "-fPIC".}

import std/[atomics, locks, options, tables]
import chronicles, chronos, chronos/threadsync, results
import
  ./ffi_types,
  ./ffi_events,
  ./ffi_handles,
  ./ffi_thread_request,
  ./ffi_request_queue,
  ./logging,
  ./cbor_serial

export ffi_events, ffi_handles

type FFIContext*[T] = object
  myLib*: ptr T # main library object (Waku, LibP2P, SDS, …)
  ffiThread: Thread[(ptr FFIContext[T])]
  eventThread: Thread[(ptr FFIContext[T])]
  reqQueueBank: RequestQueueBank
  reqSignal: ThreadSignalPtr
  stopSignal: ThreadSignalPtr
  threadExitSignal: ThreadSignalPtr
  eventQueueSignal: ThreadSignalPtr
  eventThreadExitSignal: ThreadSignalPtr
  userData*: pointer
  eventRegistry*: FFIEventRegistry
  handles*: FFIHandleRegistry
  eventQueue*: EventQueue
  ffiHeartbeat*: Atomic[int64]
  eventQueueStuck*: Atomic[bool]
  ffiThreadExited*: Atomic[bool]
    # set once FFI thread (incl. async {.ffiDtor.}) is done; event thread drains until then
  running: Atomic[bool]
  registeredRequests: ptr Table[cstring, FFIRequestProc]
  staleWarnInterval*: Duration

var onFFIThread* {.threadvar.}: bool

const git_version* {.strdefine.} = "n/a"

const
  EventThreadTickInterval* = 1.seconds
  FFIHeartbeatStartDelay* = 10.seconds
  FFIHeartbeatStaleThreshold* = 1.seconds

const StaleWarnIntervalMs* {.intdefine: "ffiStaleWarnIntervalMs".} = 5000
  ## `RET_STALE_WARN` cadence; handlers are never timed out.
const StaleWarnInterval* = StaleWarnIntervalMs.milliseconds

type FFITeardownProc*[T] = proc(lib: ptr T): Future[void] {.async.}

proc ffiTeardownHook*[T](): var FFITeardownProc[T] =
  ## Per-library teardown slot (one `{.global.}` per `T`), awaited by the FFI thread before exit.
  ## Runtime slot not an overload: an overload would bind the no-op default before the dtor is visible.
  var hook {.global.}: FFITeardownProc[T]
  hook

include ./event_thread
include ./ffi_thread

template closeAndNil(field: untyped) =
  if not field.isNil():
    ?field.close()
    field = nil

proc deinitContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## Mirror of `initContextResources`. Threads MUST be joined first; fields nil'd after close.
  deinitRequestQueue(ctx[].reqQueueBank)
  deinitEventRegistry(ctx[].eventRegistry)
  deinitHandleRegistry(ctx[].handles)
  deinitEventQueue(ctx[].eventQueue)
  when defined(gcRefc):
    # ThreadSignalPtr.close() under refc hangs via signal-handler re-entry; leak the bounded fd.
    discard
  else:
    closeAndNil(ctx.reqSignal)
    closeAndNil(ctx.stopSignal)
    closeAndNil(ctx.threadExitSignal)
    closeAndNil(ctx.eventQueueSignal)
    closeAndNil(ctx.eventThreadExitSignal)
  ok()

template newSignalOrErr(field: untyped, name: string) =
  field = ThreadSignalPtr.new().valueOr:
    return err("couldn't create ThreadSignalPtr: " & name & ": " & $error)

proc initContextResources*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On failure, deferred cleanup closes partial state; caller releases the slot.
  # Nil first so deferred cleanup can't double-close a reused pool slot.
  ctx.reqSignal = nil
  ctx.stopSignal = nil
  ctx.threadExitSignal = nil
  ctx.eventQueueSignal = nil
  ctx.eventThreadExitSignal = nil
  initRequestQueue(ctx[].reqQueueBank)
  initEventRegistry(ctx[].eventRegistry)
  initHandleRegistry(ctx[].handles)
  initEventQueue(ctx[].eventQueue)
  ctx.ffiHeartbeat.store(0)
  ctx.eventQueueStuck.store(false)
  ctx.ffiThreadExited.store(false)
  ctx.staleWarnInterval = StaleWarnInterval

  var success = false
  defer:
    if not success:
      # `ctx` is a pool slot the caller owns; close what was opened, never free it.
      ctx.deinitContextResources().isOkOr:
        error "failed to clean up resources after createFFIContext failure",
          error = error

  newSignalOrErr(ctx.reqSignal, "reqSignal")
  newSignalOrErr(ctx.stopSignal, "stopSignal")
  newSignalOrErr(ctx.threadExitSignal, "threadExitSignal")
  newSignalOrErr(ctx.eventQueueSignal, "eventQueueSignal")
  newSignalOrErr(ctx.eventThreadExitSignal, "eventThreadExitSignal")

  ctx.registeredRequests = addr ffi_types.registeredRequests

  ctx.running.store(true)

  try:
    createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    return err("failed to create the FFI thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.eventThread, eventThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    # Join ffiThread before deferred cleanup closes signals it's waiting on.
    ctx.running.store(false)
    let fireRes = ctx.reqSignal.fireSync()
    if fireRes.isErr():
      error "failed to signal ffiThread during event-thread cleanup",
        error = fireRes.error
    joinThread(ctx.ffiThread)
    return err("failed to create the event thread: " & getCurrentExceptionMsg())

  success = true
  ok()

proc fireOrErr(sig: ThreadSignalPtr, name: string): Result[void, string] =
  let fired = sig.fireSync().valueOr:
    return err("error signaling: " & name & ": " & $error)
  if not fired:
    return err("failed to signal: " & name & " on time")
  ok()

proc waitExitOrErr(
    sig: ThreadSignalPtr, name: string, timeout: Duration
): Result[void, string] =
  let exited = sig.waitSync(timeout).valueOr:
    return err("error waiting for exit: " & name & ": " & $error)
  if not exited:
    return err("did not exit in time: " & name & " (leaking ctx to avoid hang)")
  ok()

proc signalStop*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  # Skip onNotResponding on error: it takes reg.lock a stuck listener may hold (deadlock risk).
  ctx.running.store(false)
  ?ctx.reqSignal.fireOrErr("reqSignal")
  ?ctx.stopSignal.fireOrErr("stopSignal")
  ctx.eventQueueSignal.fireOrErr("eventQueueSignal").isOkOr:
    error "failed to signal eventQueueSignal in signalStop", error = error
  ok()

## Per-thread exit wait before stopAndJoinThreads leaks ctx rather than hanging; async
## `{.ffiDtor.}` teardown can outlast the default. Override `-d:ffiThreadExitTimeoutMs=<ms>`.
const ThreadExitTimeoutMs* {.intdefine: "ffiThreadExitTimeoutMs".} = 1500
const ThreadExitTimeout* = ThreadExitTimeoutMs.milliseconds

proc stopAndJoinThreads*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ## On timeout, returns err and skips remaining joins (leaves threads live); caller cleans up.
  ctx.signalStop().isOkOr:
    return err("signalStop failed: " & $error)

  ?ctx.threadExitSignal.waitExitOrErr("FFI thread", ThreadExitTimeout)
  joinThread(ctx.ffiThread)
  ?ctx.eventThreadExitSignal.waitExitOrErr("event thread", ThreadExitTimeout)
  joinThread(ctx.eventThread)
  ok()
