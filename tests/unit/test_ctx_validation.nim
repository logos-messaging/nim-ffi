import std/[atomics, locks]
import unittest2
import results
import ffi

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
  # A nil or offset-invalid ctx must yield RET_ERR via callback and return, never crash.
  test "nil ctx with valid callback returns RET_ERR via callback, no crash":
    var s: CallbackState
    initCbState(s)
    let nilCtx: ptr FFIContext[TestLib] = nil
    let ret = ctxval_ping(nilCtx, validationCallback, addr s, nil, 0.csize_t)
    check ret == RET_ERR
    check s.called.load()
    check s.retCode == RET_ERR

  test "invalid non-nil ctx (offset-pointer) returns RET_ERR, no crash":
    var s: CallbackState
    initCbState(s)
    let invalidCtx = cast[ptr FFIContext[TestLib]](123)
    let ret = ctxval_ping(invalidCtx, validationCallback, addr s, nil, 0.csize_t)
    check ret == RET_ERR
    check s.called.load()
    check s.retCode == RET_ERR
