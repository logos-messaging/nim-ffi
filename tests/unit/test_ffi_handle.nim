## {.ffiHandle.} round-trip: a handle crosses as uint64; stale/forged/null ids RET_ERR.

import std/[locks, strutils]
import unittest2
import results
import ffi

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

type CallbackData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  msg: array[1024, byte]
  msgLen: int

proc initCallbackData(d: var CallbackData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitCallbackData(d: var CallbackData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

proc testCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].retCode = retCode
  let n = min(int(len), d[].msg.len)
  if n > 0 and not msg.isNil:
    copyMem(addr d[].msg[0], msg, n)
  d[].msgLen = n
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc waitCallback(d: var CallbackData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc payload(d: var CallbackData): seq[byte] =
  var b = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr b[0], addr d.msg[0], d.msgLen)
  b

proc text(d: var CallbackData): string =
  var s = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr s[0], addr d.msg[0], d.msgLen)
  s

proc encodedPtr(b: var seq[byte]): ptr byte =
  if b.len == 0:
    nil
  else:
    cast[ptr byte](addr b[0])

template runCall(d, ctx, reqBytes, exportProc) =
  initCallbackData(d)
  var rb = reqBytes
  check exportProc(ctx, testCallback, addr d, encodedPtr(rb), rb.len.csize_t) == RET_OK
  waitCallback(d)

suite "{.ffiHandle.} round-trip":
  setup:
    let ctx {.inject.} = HandleLibFFIPool.createFFIContext().get()

  teardown:
    discard HandleLibFFIPool.destroyFFIContext(ctx)

  test "handle returned as uint64, reconstituted on the next call":
    var od: CallbackData
    runCall(
      od,
      ctx,
      cborEncode(HandletestOpenReq(req: OpenReq(name: "alpha"))),
      handletest_open,
    )
    defer:
      deinitCallbackData(od)
    check od.retCode == RET_OK
    let handle = cborDecode(payload(od), uint64).value
    check handle == 1'u64

    var td: CallbackData
    runCall(td, ctx, cborEncode(HandletestTokenReq(s: handle)), handletest_token)
    defer:
      deinitCallbackData(td)
    check td.retCode == RET_OK
    check cborDecode(payload(td), string).value == "alpha:0#1"

  test "handle as receiver (first param)":
    var od: CallbackData
    runCall(
      od,
      ctx,
      cborEncode(HandletestOpenReq(req: OpenReq(name: "beta"))),
      handletest_open,
    )
    defer:
      deinitCallbackData(od)
    let handle = cborDecode(payload(od), uint64).value

    var bd: CallbackData
    runCall(
      bd, ctx, cborEncode(HandletestSessionBumpReq(s: handle)), handletest_session_bump
    )
    defer:
      deinitCallbackData(bd)
    check bd.retCode == RET_OK
    check cborDecode(payload(bd), int).value == 1

  test "forged handle misses cleanly with RET_ERR":
    var td: CallbackData
    runCall(td, ctx, cborEncode(HandletestTokenReq(s: 9999'u64)), handletest_token)
    defer:
      deinitCallbackData(td)
    check td.retCode == RET_ERR
    check "ffiHandle" in text(td)

  test "null handle (0) misses with RET_ERR":
    var td: CallbackData
    runCall(td, ctx, cborEncode(HandletestTokenReq(s: 0'u64)), handletest_token)
    defer:
      deinitCallbackData(td)
    check td.retCode == RET_ERR
