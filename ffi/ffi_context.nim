{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net, locks, json]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import ./ffi_types, ./ffi_thread_request, ./internal/ffi_macro, ./logging

type FFIContext*[T] = object
  myLib*: T
    # main library object (e.g., Waku, LibP2P, SDS,  the one to be exposed as a library)
  ffiThread: Thread[(ptr FFIContext[T])]
    # represents the main FFI thread in charge of attending API consumer actions
  watchdogThread: Thread[(ptr FFIContext[T])]
    # monitors the FFI thread and notifies the FFI API consumer if it hangs
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr FFIThreadRequest]
  reqSignal: ThreadSignalPtr # to notify the FFI Thread that a new request is sent
  reqReceivedSignal: ThreadSignalPtr
    # to signal main thread, interfacing with the FFI thread, that FFI thread received the request
  userData*: pointer
  eventCallback*: pointer
  eventUserdata*: pointer
  running: Atomic[bool] # To control when the threads are running
  registeredRequests: ptr Table[cstring, FFIRequestProc]
    # Pointer to with the registered requests at compile time

const git_version* {.strdefine.} = "n/a"

template callEventCallback*(ctx: ptr FFIContext, eventName: string, body: untyped) =
  if isNil(ctx[].eventCallback):
    chronicles.error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[FFICallBack](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[FFICallBack](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

proc sendRequestToFFIThread*(
    ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest, timeout = InfiniteDuration
): Result[void, string] =
  ctx.lock.acquire()
  # This lock is only necessary while we use a SP Channel and while the signalling
  # between threads assumes that there aren't concurrent requests.
  # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
  # requests concurrently and spare us the need of locks
  defer:
    ctx.lock.release()

  ## Sending the request
  let sentOk = ctx.reqChannel.trySend(ffiRequest)
  if not sentOk:
    return err("Couldn't send a request to the ffi thread")

  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    return err("failed fireSync: " & $fireSyncRes.error)

  if fireSyncRes.get() == false:
    return err("Couldn't fireSync in time")

  ## wait until the Waku Thread properly received the request
  let res = ctx.reqReceivedSignal.waitSync(timeout)
  if res.isErr():
    return err("Couldn't receive reqReceivedSignal signal")

  ## Notice that in case of "ok", the deallocShared(req) is performed by the Waku Thread in the
  ## process proc. See the 'waku_thread_request.nim' module for more details.
  ok()

type Foo = object
registerReqFFI(WatchdogReq, foo: ptr Foo):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("waku thread is not blocked")

type JsonNotRespondingEvent = object
  eventType: string

proc init(T: type JsonNotRespondingEvent): T =
  return JsonNotRespondingEvent(eventType: "not_responding")

proc `$`(event: JsonNotRespondingEvent): string =
  $(%*event)

proc onNotResponding*(ctx: ptr FFIContext) =
  callEventCallback(ctx, "onWakuNotResponsive"):
    $JsonNotRespondingEvent.init()

proc watchdogThreadBody(ctx: ptr FFIContext) {.thread.} =
  ## Watchdog thread that monitors the Waku thread and notifies the library user if it hangs.

  let watchdogRun = proc(ctx: ptr FFIContext) {.async.} =
    const WatchdogStartDelay = 10.seconds
    const WatchdogTimeinterval = 1.seconds
    const WakuNotRespondingTimeout = 3.seconds

    # Give time for the node to be created and up before sending watchdog requests
    await sleepAsync(WatchdogStartDelay)
    while true:
      await sleepAsync(WatchdogTimeinterval)

      if ctx.running.load == false:
        debug "Watchdog thread exiting because FFIContext is not running"
        break

      let wakuCallback = proc(
          callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
      ) {.cdecl, gcsafe, raises: [].} =
        discard ## Don't do anything. Just respecting the callback signature.
      const nilUserData = nil

      trace "Sending watchdog request to FFI thread"

      sendRequestToFFIThread(ctx, WatchdogReq.ffiNewReq(wakuCallback, nilUserData)).isOkOr:
        error "Failed to send watchdog request to FFI thread", error = $error
        onNotResponding(ctx)

  waitFor watchdogRun(ctx)

proc ffiThreadBody[T](ctx: ptr FFIContext[T]) {.thread.} =
  ## FFI thread that attends library user API requests

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  let ffiRun = proc(ctx: ptr FFIContext[T]) {.async.} =
    while true:
      await ctx.reqSignal.wait()

      if ctx.running.load == false:
        break

      ## Wait for a request from the ffi consumer thread
      var request: ptr FFIThreadRequest
      let recvOk = ctx.reqChannel.tryRecv(request)
      if not recvOk:
        chronicles.error "ffi thread could not receive a request"
        continue

      ## Handle the request
      asyncSpawn FFIThreadRequest.process(
        request, addr ctx.myLib, ctx.registeredRequests
      )

      let fireRes = ctx.reqReceivedSignal.fireSync()
      if fireRes.isErr():
        error "could not fireSync back to requester thread", error = fireRes.error

  waitFor ffiRun(ctx)

proc createFFIContext*[T](): Result[ptr FFIContext[T], string] =
  ## This proc is called from the main thread and it creates
  ## the FFI working thread.
  var ctx = createShared(FFIContext[T], 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr")
  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqReceivedSignal ThreadSignalPtr")
  ctx.lock.initLock()
  ctx.registeredRequests = addr ffi_types.registeredRequests

  ctx.running.store(true)

  try:
    createThread(ctx.ffiThread, ffiThreadBody[T], ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err("failed to create the Waku thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.watchdogThread, watchdogThreadBody, ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err("failed to create the watchdog thread: " & getCurrentExceptionMsg())

  return ok(ctx)

proc destroyFFIContext*[T](ctx: ptr FFIContext[T]): Result[void, string] =
  ctx.running.store(false)

  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("error in destroyFFIContext: " & $error)
  if not signaledOnTime:
    return err("failed to signal reqSignal on time in destroyFFIContext")

  joinThread(ctx.ffiThread)
  joinThread(ctx.watchdogThread)
  ctx.lock.deinitLock()
  ?ctx.reqSignal.close()
  ?ctx.reqReceivedSignal.close()
  freeShared(ctx)

  return ok()

template checkParams*(ctx: ptr FFIContext, callback: FFICallBack, userData: pointer) =
  if not isNil(ctx):
    ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK
