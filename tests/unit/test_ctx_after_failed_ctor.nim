import std/[atomics, os]
import unittest2
import results
import ffi
import ./helpers

# A call queued behind a failed ctor must not reach the user body: a `ref` lib's fallback is nil.

type FailedCtorLib = ref object
  marker: int

# A stub for the NimMain proc that declareLibrary imports. The test links as a
# plain executable.
{.emit: "void libfailedctorNimMain(void) {}".}

declareLibrary("failedctor", FailedCtorLib)

type FailedCtorConfig {.ffi.} = object
  shouldFail: bool
  shouldRaise: bool

proc failedctor_create*(
    config: FailedCtorConfig
): Future[Result[FailedCtorLib, string]] {.ffiCtor.} =
  if config.shouldRaise:
    raise newException(ValueError, "ctor deliberately raised")
  if config.shouldFail:
    return err("ctor deliberately failed")
  return ok(FailedCtorLib(marker: 1))

proc failedctor_destroy*(lib: FailedCtorLib) {.ffiDtor.} =
  discard

# Both bodies read a field. A nil ref receiver faults on that read.
proc failedctor_ping*(lib: FailedCtorLib): Future[Result[string, string]] {.ffi.} =
  return ok("pong:" & $lib.marker)

proc failedctor_echo*(
    lib: FailedCtorLib, note: string
): Future[Result[string, string]] {.ffi.} =
  return ok(note & ":" & $lib.marker)

type CallbackState = object
  called: Atomic[bool]
  retCode: Atomic[int]

proc resetState(s: var CallbackState) =
  s.called.store(false)
  s.retCode.store(-1)

proc recordingCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let s = cast[ptr CallbackState](userData)
  s[].retCode.store(int(retCode))
  s[].called.store(true)

proc waitCalled(s: var CallbackState): bool =
  var tries = 0
  while not s.called.load() and tries < 500:
    os.sleep(5)
    inc tries
  s.called.load()

proc startCtor(s: var CallbackState, config: FailedCtorConfig): FFICtxToken =
  ## The callback has not necessarily run on return.
  resetState(s)
  var cfg = cborEncode(FailedctorCreateCtorReq(config: config))
  failedctor_create(encodedPtr(cfg), cfg.len.csize_t, recordingCallback, addr s)

proc startFailedCtor(s: var CallbackState): FFICtxToken =
  startCtor(s, FailedCtorConfig(shouldFail: true))

proc checkSlotGivenBack(s: var CallbackState, tok: FFICtxToken) =
  let ctx = FailedCtorLibFFIPool.resolveCtx(tok)
  check not ctx.isNil()
  check waitCalled(s)
  check s.retCode.load() == int(RET_ERR)
  waitSlotFree(ctx)
  check FailedCtorLibFFIPool.resolveCtx(tok).isNil()
  check failedctor_destroy(tok) == RET_ERR

proc callRejectedOrFailed(ret: cint, s: var CallbackState): bool =
  ## A call that races the recycle is refused on submit or answered with RET_ERR.
  ret != RET_OK or (waitCalled(s) and s.retCode.load() == int(RET_ERR))

suite "{.ffi.} call after a failed constructor":
  test "a failed ctor gives its slot back, and its token stops resolving":
    let quarantined = FailedCtorLibFFIPool.quarantinedSlots()
    for _ in 0 ..< MaxFFIContexts + 8:
      var failed: CallbackState
      check not startFailedCtor(failed).isNil()
      check waitCalled(failed)
      check failed.retCode.load() == int(RET_ERR)

    var s: CallbackState
    checkSlotGivenBack(s, startFailedCtor(s))
    check FailedCtorLibFFIPool.quarantinedSlots() == quarantined

  test "calls behind a failed ctor report an error, no crash":
    var ctorState, pingState, echoState: CallbackState
    let tok = startFailedCtor(ctorState)
    check not tok.isNil()

    resetState(pingState)
    resetState(echoState)
    var pingReq = cborEncode(FailedctorPingReq())
    var echoReq = cborEncode(FailedctorEchoReq(note: "hello"))
    let pingRet = failedctor_ping(
      tok, recordingCallback, addr pingState, encodedPtr(pingReq), pingReq.len.csize_t
    )
    let echoRet = failedctor_echo(
      tok, recordingCallback, addr echoState, encodedPtr(echoReq), echoReq.len.csize_t
    )
    check callRejectedOrFailed(pingRet, pingState)
    check callRejectedOrFailed(echoRet, echoState)
    check waitCalled(ctorState)

  # The guard runs on the FFI thread, behind the ctor in the queue. Thus a host
  # can send a call before it waits for the create callback.
  test "a call issued before the successful ctor callback still succeeds":
    var ctorState: CallbackState
    resetState(ctorState)
    var cfg =
      cborEncode(FailedctorCreateCtorReq(config: FailedCtorConfig(shouldFail: false)))
    let raw = failedctor_create(
      encodedPtr(cfg), cfg.len.csize_t, recordingCallback, addr ctorState
    )
    check not raw.isNil()
    let ctx = FailedCtorLibFFIPool.resolveCtx(raw)

    # No wait here, on purpose: the request goes into the queue behind the ctor.
    var callState: CallbackState
    resetState(callState)
    var req = cborEncode(FailedctorPingReq())
    let ret = failedctor_ping(
      ctx.ffiToken(),
      recordingCallback,
      addr callState,
      encodedPtr(req),
      req.len.csize_t,
    )
    check ret == RET_OK
    check waitCalled(callState)
    check callState.retCode.load() == int(RET_OK)

  test "a ctor body that raises gives its slot back, and its token stops resolving":
    var s: CallbackState
    checkSlotGivenBack(s, startCtor(s, FailedCtorConfig(shouldRaise: true)))

  # Without this, a recycle on every ctor exit would also pass the failure tests.
  test "a successful ctor keeps its slot, and its token still destroys":
    var s: CallbackState
    let tok = startCtor(s, FailedCtorConfig())
    check not tok.isNil()
    check waitCalled(s)
    check s.retCode.load() == int(RET_OK)
    check not FailedCtorLibFFIPool.resolveCtx(tok).isNil()

    var pingState: CallbackState
    resetState(pingState)
    var req = cborEncode(FailedctorPingReq())
    check failedctor_ping(
      tok, recordingCallback, addr pingState, encodedPtr(req), req.len.csize_t
    ) == RET_OK
    check waitCalled(pingState)
    check pingState.retCode.load() == int(RET_OK)
    check failedctor_destroy(tok) == RET_OK

suite "{.ffiCtor.} with a NULL callback":
  test "the ctor refuses a NULL callback, claims no slot, and does not crash":
    var cfg =
      cborEncode(FailedctorCreateCtorReq(config: FailedCtorConfig(shouldFail: false)))
    for _ in 0 ..< MaxFFIContexts * 2:
      check failedctor_create(encodedPtr(cfg), cfg.len.csize_t, nil, nil).isNil()
    check $lastError() == "callback must not be NULL"

    var s: CallbackState
    resetState(s)
    let later =
      failedctor_create(encodedPtr(cfg), cfg.len.csize_t, recordingCallback, addr s)
    check not later.isNil()
    check waitCalled(s)
    check s.retCode.load() == int(RET_OK)
