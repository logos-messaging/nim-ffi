## A callback that destroys its own context gets RET_ERR at once and leaves the
## context live; the recycle would wait on the thread that runs the callback.

import std/[atomics, monotimes]
from std/times import inMilliseconds
import unittest2
import results
import ffi
import ./helpers

type SelfDestroyLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libselfdestroyNimMain(void) {}".}

declareLibrary("selfdestroy", SelfDestroyLib)

proc selfdestroy_create*(): Future[Result[SelfDestroyLib, string]] {.ffiCtor.} =
  return ok(SelfDestroyLib())

proc onFatal*(code: int) {.ffiEvent.}

proc selfdestroy_ping*(
    lib: SelfDestroyLib, fire: bool
): Future[Result[int, string]] {.ffi.} =
  if fire:
    onFatal(1)
  return ok(1)

proc selfdestroy_destroy*(lib: SelfDestroyLib) {.ffiDtor.} =
  discard

const
  FailFastLimitMs = 100
  ReplyTimeoutMs = 5000

startWatchdog(60_000, "a destroy from inside a callback never returned")

var
  gTarget: FFICtxToken
  gDestroyRet: Atomic[int]
  gDestroyMs: Atomic[int]
  gDestroyed: Atomic[bool]

proc destroyTarget() =
  let started = getMonoTime()
  {.cast(gcsafe).}:
    gDestroyRet.store(int(selfdestroy_destroy(gTarget)))
  gDestroyMs.store(int((getMonoTime() - started).inMilliseconds()))
  gDestroyed.store(true)

proc destroyInReply(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  if retCode == RET_STALE_WARN:
    return
  destroyTarget()

proc destroyInListener(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  destroyTarget()

proc createCtx(): FFICtxToken =
  var cfg = cborEncode(SelfdestroyCreateCtorReq())
  let token = selfdestroy_create(encodedPtr(cfg), cfg.len.csize_t, noopCallback, nil)
  doAssert not token.isNil(), "the ctor failed"
  doAssert waitFlag(SelfDestroyLibFFIPool.resolveCtx(token)[].libReady)
  token

proc ping(
    token: FFICtxToken, fire: bool, callback: FFICallBack, userData: pointer = nil
) =
  var req = cborEncode(SelfdestroyPingReq(fire: fire))
  doAssert selfdestroy_ping(token, callback, userData, encodedPtr(req), req.len.csize_t) ==
    RET_OK

proc armDestroy(target: FFICtxToken) =
  gTarget = target
  gDestroyed.store(false)
  gDestroyRet.store(-1)
  gDestroyMs.store(-1)

template checkRefusedThenDestroyed(token: FFICtxToken, quarantined: int) =
  check waitFlag(gDestroyed)
  check gDestroyRet.load() == RET_ERR
  check gDestroyMs.load() < FailFastLimitMs
  check SelfDestroyLibFFIPool.isValidCtx(token)

  setupCallbackData(rsp)
  ping(token, false, testCallback, addr rsp)
  check rsp.waitCallbackTimeout(ReplyTimeoutMs)
  check rsp.retCode == RET_OK
  check cborDecode(rsp.payload(), int).get() == 1

  check selfdestroy_destroy(token) == RET_OK
  check not SelfDestroyLibFFIPool.isValidCtx(token)
  check SelfDestroyLibFFIPool.quarantinedSlots() == quarantined

template checkOtherDestroyed(caller, target: FFICtxToken, quarantined: int) =
  check waitFlag(gDestroyed)
  check gDestroyRet.load() == RET_OK
  check not SelfDestroyLibFFIPool.isValidCtx(target)

  check selfdestroy_destroy(caller) == RET_OK
  check SelfDestroyLibFFIPool.quarantinedSlots() == quarantined

suite "destroy from inside a callback":
  setup:
    let quarantined = SelfDestroyLibFFIPool.quarantinedSlots()

  test "a reply callback cannot destroy its own context":
    let token = createCtx()
    armDestroy(token)
    ping(token, false, destroyInReply)

    checkRefusedThenDestroyed(token, quarantined)

  test "a listener cannot destroy its own context":
    let token = createCtx()
    let ctx = SelfDestroyLibFFIPool.resolveCtx(token)
    check addEventListener(ctx[].eventRegistry, "on_fatal", destroyInListener, nil) > 0
    armDestroy(token)
    ping(token, true, noopCallback)

    checkRefusedThenDestroyed(token, quarantined)

  test "a reply callback can destroy a different context":
    let caller = createCtx()
    let target = createCtx()
    armDestroy(target)
    ping(caller, false, destroyInReply)

    checkOtherDestroyed(caller, target, quarantined)

  test "a listener can destroy a different context":
    let caller = createCtx()
    let target = createCtx()
    let ctx = SelfDestroyLibFFIPool.resolveCtx(caller)
    check addEventListener(ctx[].eventRegistry, "on_fatal", destroyInListener, nil) > 0
    armDestroy(target)
    ping(caller, true, noopCallback)

    checkOtherDestroyed(caller, target, quarantined)
