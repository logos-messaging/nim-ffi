## A listener that mutates the registry from inside its own callback must not
## wedge the event thread, and a remove from another thread must wait out the
## delivery in flight.

import std/[atomics, os]
import unittest2
import results
import ffi
import ./helpers

type ReentrantLib = object

registerReqFFI(EmitReentrantEvent, lib: ptr ReentrantLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEventCbor("reentrant", 0)
    return ok("emitted")

proc watchdogBody(timeoutMs: int) {.thread.} =
  ## Unpatched, a dispatch never returns, so the process must die on its own.
  os.sleep(timeoutMs)
  echo "watchdog: a dispatch never returned"
  quit(1)

var watchdog: Thread[int]
createThread(watchdog, watchdogBody, 60_000)

var
  gReg: ptr FFIEventRegistry
  gSelfId: uint64
  gAddedId: uint64
  gRemoved: Atomic[bool]
  gDispatched: Atomic[bool]
  gEntered: Atomic[bool]
  gRelease: Atomic[bool]
  gRemoveReturned: Atomic[bool]

proc noopCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

proc mutateCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Mutates the registry it is dispatched from.
  gRemoved.store(removeEventListener(gReg[], gSelfId))
  when not defined(gcRefc):
    # refc: the event thread must not allocate into the heap that owns the registry.
    gAddedId = addEventListener(gReg[], "reentrant", noopCb, nil)
  gDispatched.store(true)

proc blockCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  gEntered.store(true)
  while not gRelease.load():
    os.sleep(5)

proc removerBody(listenerId: uint64) {.thread.} =
  discard removeEventListener(gReg[], listenerId)
  gRemoveReturned.store(true)

template withPool(ctxIdent: untyped, body: untyped) =
  var pool: FFIContextPool[ReentrantLib]
  let ctxIdent = pool.createFFIContext().valueOr:
    check false
    return
  defer:
    discard pool.destroyFFIContext(ctxIdent)
  body

suite "listener reentrancy":
  test "a listener mutates the registry from inside its own callback":
    withPool(ctx):
      gReg = addr ctx[].eventRegistry
      gSelfId = addEventListener(ctx[].eventRegistry, "reentrant", mutateCb, nil)
      check gSelfId > 0
      check sendRequestToFFIThread(ctx, EmitReentrantEvent.ffiNewReq(noopCb, nil)).isOk()

      check waitFlag(gDispatched)
      check gRemoved.load()
      when defined(gcRefc):
        check snapshotListeners(ctx[].eventRegistry, "reentrant").len == 0
      else:
        check gAddedId > gSelfId
        check snapshotListeners(ctx[].eventRegistry, "reentrant").len == 1

  test "a remove from another thread waits for the delivery in flight":
    withPool(ctx):
      gReg = addr ctx[].eventRegistry
      let id = addEventListener(ctx[].eventRegistry, "reentrant", blockCb, nil)
      check sendRequestToFFIThread(ctx, EmitReentrantEvent.ffiNewReq(noopCb, nil)).isOk()
      check waitFlag(gEntered)

      var remover: Thread[uint64]
      createThread(remover, removerBody, id)
      os.sleep(200)
      check not gRemoveReturned.load() # the callback still runs

      gRelease.store(true)
      joinThread(remover)
      check snapshotListeners(ctx[].eventRegistry, "reentrant").len == 0
