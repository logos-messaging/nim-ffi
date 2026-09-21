## {.ffiHandle.} round-trip: a handle crosses as uint64; stale/forged/null ids RET_ERR.

import std/strutils
import unittest2
import results
import ffi
import ./helpers

type HandleLib = object
  base: int

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libhandletestNimMain(void) {}".}

declareLibrary("handletest", HandleLib)

type Session {.ffiHandle.} = ref object
  token: string
  hits: int

type OpenReq {.ffi.} = object
  name: string

proc handletest_open*(
    lib: HandleLib, req: OpenReq
): Future[Result[Session, string]] {.ffi.} =
  return ok(Session(token: req.name & ":" & $lib.base, hits: 0))

proc handletest_token*(
    lib: HandleLib, s: Session
): Future[Result[string, string]] {.ffi.} =
  s.hits.inc()
  return ok(s.token & "#" & $s.hits)

# Handle as the receiver (first param).
proc handletest_session_bump*(s: Session): Future[Result[int, string]] {.ffi.} =
  s.hits.inc()
  return ok(s.hits)

template runCall(ctx, req, exportProc: untyped): PolledMsg =
  ## A template: the export shares its name with the Nim-native proc, so only a call resolves it.
  block:
    var rb = cborEncode(req)
    var reqId: uint64
    doAssert exportProc(ctx.ffiToken(), encodedPtr(rb), rb.len.csize_t, addr reqId) ==
      RET_OK
    pollReply(ctx, reqId)

suite "{.ffiHandle.} round-trip":
  setup:
    let ctx {.inject.} = HandleLibFFIPool.createFFIContext().get()

  teardown:
    discard HandleLibFFIPool.destroyFFIContext(ctx)

  test "handle returned as uint64, reconstituted on the next call":
    let opened =
      runCall(ctx, HandletestOpenReq(req: OpenReq(name: "alpha")), handletest_open)
    check opened.retCode == RET_OK
    let handle = cborDecode(opened.payload, uint64).value
    check handle == 1'u64

    check runCall(ctx, HandletestTokenReq(s: handle), handletest_token).okString() ==
      "alpha:0#1"

  test "handle as receiver (first param)":
    let opened =
      runCall(ctx, HandletestOpenReq(req: OpenReq(name: "beta")), handletest_open)
    let handle = cborDecode(opened.payload, uint64).value

    let bumped =
      runCall(ctx, HandletestSessionBumpReq(s: handle), handletest_session_bump)
    check bumped.retCode == RET_OK
    check cborDecode(bumped.payload, int).value == 1

  test "forged handle misses cleanly with RET_ERR":
    let missed = runCall(ctx, HandletestTokenReq(s: 9999'u64), handletest_token)
    check missed.retCode == RET_ERR
    check "ffiHandle" in missed.text()

  test "null handle (0) misses with RET_ERR":
    check runCall(ctx, HandletestTokenReq(s: 0'u64), handletest_token).retCode == RET_ERR
