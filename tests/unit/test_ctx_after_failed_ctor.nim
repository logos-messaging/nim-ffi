import std/atomics
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

proc failedctor_destroy*(lib: FailedCtorLib) {.ffiDtor.} =
  discard

proc createCtx(shouldFail: bool, ctorReqId: var uint64): ptr FFIContext[FailedCtorLib] =
  ## The token comes back at once; whether the ctor worked is a reply on the new context.
  var cfg = cborEncode(
    FailedctorCreateCtorReq(config: FailedCtorConfig(shouldFail: shouldFail))
  )
  var token: FFICtxToken
  if failedctor_create(encodedPtr(cfg), cfg.len.csize_t, addr token, addr ctorReqId) !=
      RET_OK:
    return nil
  return FailedCtorLibFFIPool.resolveCtx(token)

proc createFailedCtx(): ptr FFIContext[FailedCtorLib] =
  ## Sends the ctor down its error path and returns the context, which stays alive.
  var ctorReqId: uint64
  let ctx = createCtx(true, ctorReqId)
  if ctx.isNil():
    return nil
  let reply = pollReply(ctx, ctorReqId)
  doAssert reply.ret == RET_OK and reply.retCode == RET_ERR
  doAssert reply.text() == "ctor deliberately failed"
  return ctx

suite "{.ffi.} call after a failed constructor":
  test "the failed ctor reports the error but leaves the context alive":
    let ctx = createFailedCtx()
    check not ctx.isNil()
    # `myLib` is not nil even here. The FFI thread points it at a default
    # fallback before it dispatches the request. `libReady` shows if the ctor
    # stored a real library.
    check not ctx[].myLib.isNil() # the fallback, not a real library
    check ctx[].myLib[].isNil() # for a `ref` lib the fallback is nil
    check not ctx[].libReady.load()

  # The synchronous return only reports that the FFI thread accepted the
  # request. The reply delivers the rejection.
  test "a no-arg call on an uninitialized library reports RET_ERR, no crash":
    let ctx = createFailedCtx()
    check not ctx.isNil()

    var req = cborEncode(FailedctorPingReq())
    var reqId: uint64
    check failedctor_ping(ctx.ffiToken(), encodedPtr(req), req.len.csize_t, addr reqId) ==
      RET_OK
    check pollReply(ctx, reqId).retCode == RET_ERR

  test "an argument-taking call on an uninitialized library reports RET_ERR, no crash":
    let ctx = createFailedCtx()
    check not ctx.isNil()

    var req = cborEncode(FailedctorEchoReq(note: "hello"))
    var reqId: uint64
    check failedctor_echo(ctx.ffiToken(), encodedPtr(req), req.len.csize_t, addr reqId) ==
      RET_OK
    check pollReply(ctx, reqId).retCode == RET_ERR

  test "the context of a failed ctor can be destroyed":
    let ctx = createFailedCtx()
    check not ctx.isNil()
    let token = ctx.ffiToken()
    check failedctor_destroy(token) == RET_OK
    check not FailedCtorLibFFIPool.isValidCtx(token)

  # The guard runs on the FFI thread, behind the ctor in the queue. Thus a host
  # can send a call before it polls the reply of the create.
  test "a call issued before the successful ctor reply still succeeds":
    var ctorReqId: uint64
    let ctx = createCtx(false, ctorReqId)
    check not ctx.isNil()

    # No wait here, on purpose: the request goes into the queue behind the ctor.
    var req = cborEncode(FailedctorPingReq())
    var reqId: uint64
    check failedctor_ping(ctx.ffiToken(), encodedPtr(req), req.len.csize_t, addr reqId) ==
      RET_OK
    check reqId > ctorReqId

    # One stream: the ctor's reply comes first, and carries CBOR null.
    let ctorReply = nextMsg(ctx)
    check ctorReply.kind == MsgReply
    check ctorReply.id == ctorReqId
    check ctorReply.retCode == RET_OK
    check ctorReply.payload == @[CborNullByte]
    check pollReply(ctx, reqId).okString() == "pong:1"
