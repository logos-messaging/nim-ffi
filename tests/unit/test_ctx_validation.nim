import std/strutils
import unittest2
import results
import ffi
import ./helpers

type TestLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libctxvaltestNimMain(void) {}".}

declareLibrary("ctxvaltest", TestLib)

type CtxValidationConfig {.ffi.} = object
  initialValue: int

proc ctxval_create*(
    config: CtxValidationConfig
): Future[Result[TestLib, string]] {.ffiCtor.} =
  return ok(TestLib())

proc ctxval_destroy*(lib: TestLib) {.ffiDtor.} =
  discard

proc ctxval_ping*(lib: TestLib): Future[Result[string, string]] {.ffi.} =
  return ok("pong")

proc refusedText(): string =
  return $ctxvaltest_last_error()

suite "ctx token validation at the FFI entry point":
  # A refused call returns a code, leaves the words in `<lib>_last_error()` and
  # produces no reply: there is no context to poll one from.
  test "a nil ctx is refused with RET_INVALID_CTX, no crash":
    var reqId = 0'u64
    let nilCtx = cast[FFICtxToken](nil)
    check ctxval_ping(nilCtx, nil, 0.csize_t, addr reqId) == RET_INVALID_CTX
    check reqId == 0
    check refusedText() == "ctx is not a valid FFI context"

  test "a forged non-nil ctx is refused with RET_INVALID_CTX, no crash":
    var reqId = 0'u64
    let invalidCtx = cast[FFICtxToken](123)
    check ctxval_ping(invalidCtx, nil, 0.csize_t, addr reqId) == RET_INVALID_CTX
    check reqId == 0
    check refusedText() == "ctx is not a valid FFI context"

  test "poll refuses the same tokens":
    var msg: ptr NimFfiMsg
    check ctxvaltest_poll(cast[FFICtxToken](nil), 0, addr msg) == RET_INVALID_CTX
    check msg.isNil()
    check ctxvaltest_poll(cast[FFICtxToken](123), 0, addr msg) == RET_INVALID_CTX
    check msg.isNil()

  test "a NULL req_id_out is refused: the reply could not be matched":
    var cfg = cborEncode(CtxvalCreateCtorReq(config: CtxValidationConfig()))
    var token: FFICtxToken
    var ctorReqId: uint64
    check ctxval_create(encodedPtr(cfg), cfg.len.csize_t, addr token, addr ctorReqId) ==
      RET_OK
    let ctx = TestLibFFIPool.resolveCtx(token)
    check not ctx.isNil()
    check pollReply(ctx, ctorReqId).retCode == RET_OK

    check ctxval_ping(token, nil, 0.csize_t, nil) == RET_ERR
    check refusedText().contains("req_id_out is NULL")
    # Refused means no reply.
    check nextMsg(ctx, 100).ret == RET_TIMEOUT
    check ctxval_destroy(token) == RET_OK

  test "a NULL ctx_out or req_id_out refuses the ctor and gives no token":
    var cfg = cborEncode(CtxvalCreateCtorReq(config: CtxValidationConfig()))
    var token: FFICtxToken
    var reqId: uint64
    check ctxval_create(encodedPtr(cfg), cfg.len.csize_t, nil, addr reqId) == RET_ERR
    check refusedText().contains("ctx_out is NULL")
    check ctxval_create(encodedPtr(cfg), cfg.len.csize_t, addr token, nil) == RET_ERR
    check token.isNil()
    check refusedText().contains("req_id_out is NULL")

  test "an undecodable ctor request is refused and gives no token":
    var junk = @[byte 0xff, 0xff, 0xff]
    var token: FFICtxToken
    var reqId: uint64
    check ctxval_create(encodedPtr(junk), junk.len.csize_t, addr token, addr reqId) ==
      RET_ERR
    check token.isNil()
    check refusedText().contains("failed to decode request")
