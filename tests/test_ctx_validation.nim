import std/locks
import unittest2
import results
import ../ffi

type TestLib = object

proc dummyCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

registerReqFFI(ValidationTestRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("ok")

suite "ctx pointer validation":
  # BUG: sendRequestToFFIThread has no nil-check on ctx.
  # checkParams / {.ffi.} generated code only guards against nil callback,
  # not nil (or otherwise invalid) ctx.  Any caller — C or Nim — that passes
  # a nil or offset-invalid ctx with a valid callback bypasses the only guard
  # and reaches ctx.lock.acquire() where the nil/garbage dereference crashes.

  test "nil ctx with valid callback should return an error, not crash":
    # Reproduces the nil case: ctx=nil, callback=valid.
    # Expected (after fix): sendRequestToFFIThread returns isErr().
    # Actual (currently)  : SIGSEGV at ctx.lock.acquire() in sendRequestToFFIThread.
    let nilCtx: ptr FFIContext[TestLib] = nil
    let req = ValidationTestRequest.ffiNewReq(dummyCallback, nil)
    let res = sendRequestToFFIThread(nilCtx, req)
    check res.isErr()

  test "invalid non-nil ctx (ctx+123 style) should return an error, not crash":
    # Reproduces the offset-pointer case: a non-nil but invalid pointer passes
    # isNil() and reaches the lock dereference, causing a crash.
    # Expected (after fix): sendRequestToFFIThread returns isErr().
    # Actual (currently)  : SIGSEGV when the garbage pointer is dereferenced.
    let invalidCtx = cast[ptr FFIContext[TestLib]](123)
    let req = ValidationTestRequest.ffiNewReq(dummyCallback, nil)
    let res = sendRequestToFFIThread(invalidCtx, req)
    check res.isErr()
