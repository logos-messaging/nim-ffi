import std/[atomics, locks]
import unittest2
import results
import ../ffi

type TestLib = object

type CtxValidationConfig {.ffi.} = object
  initialValue: int

proc ctxval_create*(
    config: CtxValidationConfig
): Future[Result[TestLib, string]] {.ffiCtor.} =
  return ok(TestLib())

proc ctxval_ping*(lib: TestLib): Future[Result[string, string]] {.ffi.} =
  return ok("pong")

type CallbackState = object
  lock: Lock
  called: Atomic[bool]
  retCode: cint

proc initCbState(s: var CallbackState) =
  s.lock.initLock()
  s.called.store(false)

proc validationCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let s = cast[ptr CallbackState](userData)
  s[].retCode = retCode
  s[].called.store(true)

suite "ctx pointer validation at the FFI entry point":
  # The macro-generated FFI entry point validates ctx via
  # <LibType>FFIPool.isValidCtx. Any caller — C or Nim — that passes a nil or
  # offset-invalid ctx with a valid callback should receive RET_ERR via the
  # callback and the proc should return RET_ERR, never crash.

  test "nil ctx with valid callback returns RET_ERR via callback, no crash":
    var s: CallbackState
    initCbState(s)
    let nilCtx: ptr FFIContext[TestLib] = nil
    let ret = ctxval_ping(nilCtx, validationCallback, addr s)
    check ret == RET_ERR
    check s.called.load()
    check s.retCode == RET_ERR

  test "invalid non-nil ctx (offset-pointer) returns RET_ERR, no crash":
    var s: CallbackState
    initCbState(s)
    let invalidCtx = cast[ptr FFIContext[TestLib]](123)
    let ret = ctxval_ping(invalidCtx, validationCallback, addr s)
    check ret == RET_ERR
    check s.called.load()
    check s.retCode == RET_ERR
