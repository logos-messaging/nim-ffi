import std/[atomics, os]
import unittest2
import results
import ffi
import ./helpers

# A {.ffiCtor.} that fails still gives the caller a live context. The ctor body
# runs on the FFI thread, long after the C entry point returns the pointer.
# `myLib` is not nil, because the FFI thread points it at a default fallback.
# For a `ref` library type that fallback is nil. A later {.ffi.} call therefore
# gave the user body a nil ref and crashed on the first field access.

type FailedCtorLib = ref object
  marker: int

# A stub for the NimMain proc that declareLibrary imports. The test links as a
# plain executable.
{.emit: "void libfailedctorNimMain(void) {}".}

declareLibrary("failedctor", FailedCtorLib)

type FailedCtorConfig {.ffi.} = object
  shouldFail: bool

proc failedctor_create*(
    config: FailedCtorConfig
): Future[Result[FailedCtorLib, string]] {.ffiCtor.} =
  if config.shouldFail:
    return err("ctor deliberately failed")
  return ok(FailedCtorLib(marker: 1))

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

proc createFailedCtx(s: var CallbackState): ptr FFIContext[FailedCtorLib] =
  ## Sends the ctor down its error path and returns the context, which stays alive.
  resetState(s)
  var cfg =
    cborEncode(FailedctorCreateCtorReq(config: FailedCtorConfig(shouldFail: true)))
  let ret =
    failedctor_create(encodedPtr(cfg), cfg.len.csize_t, recordingCallback, addr s)
  if ret.isNil():
    return nil
  discard waitCalled(s)
  FailedCtorLibFFIPool.resolveCtx(ret)

suite "{.ffi.} call after a failed constructor":
  test "the failed ctor reports the error but leaves the context alive":
    var s: CallbackState
    let ctx = createFailedCtx(s)
    check not ctx.isNil()
    check s.retCode.load() == int(RET_ERR)
    # `myLib` is not nil even here. The FFI thread points it at a default
    # fallback before it dispatches the request. `libReady` shows if the ctor
    # stored a real library.
    check not ctx[].myLib.isNil() # the fallback, not a real library
    check ctx[].myLib[].isNil() # for a `ref` lib the fallback is nil
    check not ctx[].libReady.load()

  # The synchronous return only reports that the FFI thread accepted the
  # request. The callback delivers the rejection.
  test "a no-arg call on an uninitialized library reports RET_ERR, no crash":
    var s: CallbackState
    let ctx = createFailedCtx(s)
    check not ctx.isNil()

    resetState(s)
    var req = cborEncode(FailedctorPingReq())
    let ret = failedctor_ping(
      ctx.ffiToken(), recordingCallback, addr s, encodedPtr(req), req.len.csize_t
    )
    check ret == RET_OK
    check waitCalled(s)
    check s.retCode.load() == int(RET_ERR)

  test "an argument-taking call on an uninitialized library reports RET_ERR, no crash":
    var s: CallbackState
    let ctx = createFailedCtx(s)
    check not ctx.isNil()

    resetState(s)
    var req = cborEncode(FailedctorEchoReq(note: "hello"))
    let ret = failedctor_echo(
      ctx.ffiToken(), recordingCallback, addr s, encodedPtr(req), req.len.csize_t
    )
    check ret == RET_OK
    check waitCalled(s)
    check s.retCode.load() == int(RET_ERR)

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
