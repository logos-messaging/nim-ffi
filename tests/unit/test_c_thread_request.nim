## Coverage for the C-wire payload mode added to `ffi/ffi_thread_request.nim`.
##
## The CBOR path is exercised by the existing `test_ffi_context.nim` /
## `test_serial.nim` suites; this file pins the behaviours unique to the
## pure-C target:
##   - `initFromOwnedWirePtr` adopts a typed pointer without copying.
##   - `deleteRequest` invokes the registered cleanupReqProc before
##     deallocShared'ing the struct.
##   - The defaults for the cleanup hooks are nil, so existing CBOR-path
##     code is unaffected.

import std/unittest
import results, chronos
import ../../ffi/[alloc, ffi_thread_request, ffi_types]

# Counters poked by the cleanup thunks so the tests can assert "called".
var reqCleanupCalls {.threadvar.}: int
var respCleanupCalls {.threadvar.}: int

proc reqCleanupThunk(p: pointer) {.nimcall, gcsafe, raises: [].} =
  reqCleanupCalls.inc
  # The struct itself is deallocated by `deleteRequest`; here we only
  # release whatever the wire struct *owns* (the test wire below holds a
  # single cstring).
  if p.isNil: return
  let wirePtr = cast[ptr cstring](p)
  if not wirePtr[].isNil:
    deallocShared(wirePtr[])

proc respCleanupThunk(p: pointer) {.nimcall, gcsafe, raises: [].} =
  respCleanupCalls.inc

proc noopCallback(ret: cint, msg: ptr cchar, len: csize_t, ud: pointer)
    {.cdecl, gcsafe, raises: [].} =
  discard

suite "FFIThreadRequest — C-wire payload":
  setup:
    reqCleanupCalls = 0
    respCleanupCalls = 0

  test "initFromOwnedWirePtr stores the typed pointer verbatim":
    let cstrPtr = cast[ptr cstring](allocShared(sizeof(cstring)))
    cstrPtr[] = alloc("payload")  # shared cstring owned by the wire struct

    let req = FFIThreadRequest.initFromOwnedWirePtr(
      noopCallback, nil, cstring("FakeReq"),
      cast[pointer](cstrPtr), sizeof(cstring), reqCleanupThunk
    )
    check req != nil
    check cast[pointer](req[].data) == cast[pointer](cstrPtr)
    check req[].dataLen == sizeof(cstring)
    check req[].cleanupReqProc == reqCleanupThunk
    check req[].cleanupRespData.isNil
    check req[].cleanupRespProc.isNil

    deleteRequest(req)
    # The thunk should have fired exactly once, releasing the cstring.
    check reqCleanupCalls == 1

  test "deleteRequest tolerates a nil cleanup hook":
    let cstrPtr = cast[ptr cstring](allocShared(sizeof(cstring)))
    cstrPtr[] = alloc("nofree")
    # Save the leaked cstring before deleteRequest frees the outer holder.
    let leakedCstr = cstrPtr[]
    let req = FFIThreadRequest.initFromOwnedWirePtr(
      noopCallback, nil, cstring("FakeReq"),
      cast[pointer](cstrPtr), sizeof(cstring), nil
    )
    # With no cleanup proc, the struct itself is freed but the inner
    # cstring leaks — that's the caller's contract. We just verify
    # `deleteRequest` doesn't crash.
    deleteRequest(req)
    deallocShared(leakedCstr)

  test "handleRes fires cleanupRespProc after the user callback":
    let cstrPtr = cast[ptr cstring](allocShared(sizeof(cstring)))
    cstrPtr[] = alloc("req")
    let req = FFIThreadRequest.initFromOwnedWirePtr(
      noopCallback, nil, cstring("FakeReq"),
      cast[pointer](cstrPtr), sizeof(cstring), reqCleanupThunk
    )
    # Simulate the FFI thread setting the response cleanup hook before
    # handing back to handleRes.
    let respPtr = allocShared(8)
    req[].cleanupRespData = respPtr
    req[].cleanupRespProc = respCleanupThunk

    var bytes = newSeq[byte](4) # arbitrary payload — content doesn't matter
    handleRes(Result[seq[byte], string].ok(bytes), req)

    check respCleanupCalls == 1
    check reqCleanupCalls == 1
