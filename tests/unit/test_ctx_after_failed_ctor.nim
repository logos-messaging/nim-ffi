import std/[atomics, os]
import unittest2
import results
import ffi

# A failing {.ffiCtor.} still hands the caller a live context — the ctor body
# runs on the FFI thread, long after the C entry point returned the pointer.
# `myLib` is not nil (the FFI thread points it at a default-valued fallback), but
# for a `ref` library type that default IS nil, so a later {.ffi.} call used to
# hand the user body a nil ref and crash on its first field access.

type FailedCtorLib = ref object
  marker: int

# Stub the importc NimMain declareLibrary emits (plain-exe link).
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

# Both bodies touch a field, which is what faults on a nil ref receiver.
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

proc encodedPtr(bytes: var seq[byte]): ptr byte =
  if bytes.len == 0:
    nil
  else:
    cast[ptr byte](addr bytes[0])

proc waitCalled(s: var CallbackState): bool =
  var tries = 0
  while not s.called.load() and tries < 500:
    os.sleep(5)
    inc tries
  s.called.load()

proc createFailedCtx(s: var CallbackState): ptr FFIContext[FailedCtorLib] =
  ## Drives the ctor down its error path and returns the still-live context.
  resetState(s)
  var cfg =
    cborEncode(FailedctorCreateCtorReq(config: FailedCtorConfig(shouldFail: true)))
  let ret =
    failedctor_create(encodedPtr(cfg), cfg.len.csize_t, recordingCallback, addr s)
  if ret.isNil():
    return nil
  discard waitCalled(s)
  cast[ptr FFIContext[FailedCtorLib]](ret)

suite "{.ffi.} call after a failed constructor":
  test "the failed ctor reports the error but leaves the context alive":
    var s: CallbackState
    let ctx = createFailedCtx(s)
    check not ctx.isNil()
    check s.retCode.load() == int(RET_ERR)
    # `myLib` is non-nil even here: the FFI thread points it at a default-valued
    # fallback before dispatching. `myLibOwned` is what says the ctor stored a real
    # library.
    check not ctx[].myLib.isNil() # the fallback, not a constructed library
    check ctx[].myLib[].isNil() # ...and for a `ref` lib that fallback is nil
    check not ctx[].myLibOwned

  # The synchronous return only reports that the request was accepted; the
  # rejection itself comes back through the callback.
  test "a no-arg call on an uninitialized library reports RET_ERR, no crash":
    var s: CallbackState
    let ctx = createFailedCtx(s)
    check not ctx.isNil()

    resetState(s)
    var req = cborEncode(FailedctorPingReq())
    let ret =
      failedctor_ping(ctx, recordingCallback, addr s, encodedPtr(req), req.len.csize_t)
    check ret == RET_OK
    check waitCalled(s)
    check s.retCode.load() == int(RET_ERR)

  test "an argument-taking call on an uninitialized library reports RET_ERR, no crash":
    var s: CallbackState
    let ctx = createFailedCtx(s)
    check not ctx.isNil()

    resetState(s)
    var req = cborEncode(FailedctorEchoReq(note: "hello"))
    let ret =
      failedctor_echo(ctx, recordingCallback, addr s, encodedPtr(req), req.len.csize_t)
    check ret == RET_OK
    check waitCalled(s)
    check s.retCode.load() == int(RET_ERR)

  # The guard runs on the FFI thread, behind the queued ctor, so it must not
  # penalise a host that fires a call without first awaiting the create callback.
  test "a call issued before the successful ctor callback still succeeds":
    var ctorState: CallbackState
    resetState(ctorState)
    var cfg =
      cborEncode(FailedctorCreateCtorReq(config: FailedCtorConfig(shouldFail: false)))
    let raw = failedctor_create(
      encodedPtr(cfg), cfg.len.csize_t, recordingCallback, addr ctorState
    )
    check not raw.isNil()
    let ctx = cast[ptr FFIContext[FailedCtorLib]](raw)

    # Deliberately no wait: the request queues behind the in-flight ctor.
    var callState: CallbackState
    resetState(callState)
    var req = cborEncode(FailedctorPingReq())
    let ret = failedctor_ping(
      ctx, recordingCallback, addr callState, encodedPtr(req), req.len.csize_t
    )
    check ret == RET_OK
    check waitCalled(callState)
    check callState.retCode.load() == int(RET_OK)
