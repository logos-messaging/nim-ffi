## Recycle hands the pool slot back with nothing of the previous owner left on
## it: no live handles, and no teardown at all while a handler still runs.

import std/[atomics, os, strutils]
import unittest2
import results
import ffi
import ./helpers

type RecycleLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void librecyclelibNimMain(void) {}".}

declareLibrary("recyclelib", RecycleLib)

type Session {.ffiHandle.} = ref object
  token: string

type OpenReq {.ffi.} = object
  name: string

proc recyclelib_open*(
    lib: RecycleLib, req: OpenReq
): Future[Result[Session, string]] {.ffi.} =
  return ok(Session(token: req.name))

proc recyclelib_token*(
    lib: RecycleLib, s: Session
): Future[Result[string, string]] {.ffi.} =
  return ok(s.token)

var gHold: Atomic[bool]
var gEntered: Atomic[bool]

proc waitForRelease() {.async.} =
  while gHold.load():
    await sleepAsync(10.milliseconds)

proc recyclelib_block*(lib: RecycleLib): Future[Result[int, string]] {.ffi.} =
  ## Uncancellable on purpose: `cancelSoon` cannot unwind a `noCancel`, so the
  ## drain of the recycle handler runs out of both rounds.
  gEntered.store(true)
  await noCancel(waitForRelease())
  return ok(1)

template runCall(ctx, req, exportProc: untyped): PolledMsg =
  ## A template: the export shares its name with the Nim-native proc, so only a call resolves it.
  block:
    var rb = cborEncode(req)
    var reqId: uint64
    doAssert exportProc(ctx.ffiToken(), encodedPtr(rb), rb.len.csize_t, addr reqId) ==
      RET_OK
    pollReply(ctx, reqId)

suite "recycle opens a new generation on the slot":
  test "the token of the previous owner no longer resolves":
    let first = RecycleLibFFIPool.createFFIContext().get()
    let staleToken = first.ffiToken()
    check RecycleLibFFIPool.isValidCtx(staleToken)

    check RecycleLibFFIPool.recycleFFIContext(first).isOk()
    waitSlotFree(first)
    # Between the recycle and the next claim the slot is free, so the token is
    # already dead. Reuse is the case the generation exists for.
    check not RecycleLibFFIPool.isValidCtx(staleToken)

    let second = RecycleLibFFIPool.createFFIContext().get()
    # Lowest free slot wins: same address, new owner, new generation.
    check second == first
    check second.ffiToken() != staleToken
    check not RecycleLibFFIPool.isValidCtx(staleToken)
    check RecycleLibFFIPool.resolveCtx(staleToken).isNil()

    var rb = cborEncode(RecyclelibOpenReq(req: OpenReq(name: "stale")))
    var reqId = 0'u64
    check recyclelib_open(staleToken, encodedPtr(rb), rb.len.csize_t, addr reqId) ==
      RET_INVALID_CTX
    # Refused before the enqueue: the code and the last error say so, and the new
    # owner sees neither the request nor a reply to it.
    check reqId == 0
    check $recyclelib_last_error() == "ctx is not a valid FFI context"
    check nextMsg(second, 100).ret == RET_TIMEOUT
    check second[].handles.byHandle.len == 0

    check RecycleLibFFIPool.recycleFFIContext(second).isOk()

  test "a destroyed context leaves no live token behind":
    let ctx = RecycleLibFFIPool.createFFIContext().get()
    let staleToken = ctx.ffiToken()
    check RecycleLibFFIPool.destroyFFIContext(ctx).isOk()
    check not RecycleLibFFIPool.isValidCtx(staleToken)

    let next = RecycleLibFFIPool.createFFIContext().get()
    check next == ctx
    check not RecycleLibFFIPool.isValidCtx(staleToken)
    check RecycleLibFFIPool.recycleFFIContext(next).isOk()

  test "recycle and destroy reject a context that no token resolves to":
    check RecycleLibFFIPool.recycleFFIContext(nil).isErr()
    check RecycleLibFFIPool.destroyFFIContext(nil).isErr()

suite "recycle clears the handle registry":
  test "the handle ids of the previous owner do not resolve for the next one":
    let first = RecycleLibFFIPool.createFFIContext().get()

    let opened =
      runCall(first, RecyclelibOpenReq(req: OpenReq(name: "alpha")), recyclelib_open)
    check opened.retCode == RET_OK
    let handle = cborDecode(opened.payload, uint64).value
    check handle == 1'u64
    check first[].handles.byHandle.len == 1

    check RecycleLibFFIPool.recycleFFIContext(first).isOk()
    waitSlotFree(first)
    check first[].handles.byHandle.len == 0

    let second = RecycleLibFFIPool.createFFIContext().get()
    # Lowest free slot wins, so a fresh slot here would prove nothing.
    check second == first

    check runCall(second, RecyclelibTokenReq(s: handle), recyclelib_token).retCode ==
      RET_ERR

    check RecycleLibFFIPool.recycleFFIContext(second).isOk()

  test "handles of a reused slot start from a clean table":
    let ctx = RecycleLibFFIPool.createFFIContext().get()
    for i in 0 .. 4:
      check runCall(
        ctx, RecyclelibOpenReq(req: OpenReq(name: "s" & $i)), recyclelib_open
      ).retCode == RET_OK
    check ctx[].handles.byHandle.len == 5

    check RecycleLibFFIPool.recycleFFIContext(ctx).isOk()
    check ctx[].handles.byHandle.len == 0

suite "recycle with a handler that does not drain":
  # Leaks its slot on purpose, so it runs last in this file.
  test "the recycle reports the failure and keeps the library":
    let ctx = RecycleLibFFIPool.createFFIContext().get()

    gHold.store(true)
    gEntered.store(false)
    var rb = cborEncode(RecyclelibBlockReq())
    var blockReqId: uint64
    check recyclelib_block(
      ctx.ffiToken(), encodedPtr(rb), rb.len.csize_t, addr blockReqId
    ) == RET_OK
    while not gEntered.load():
      os.sleep(5)

    let t0 = Moment.now()
    let res = RecycleLibFFIPool.recycleFFIContext(ctx)
    let elapsed = Moment.now() - t0

    # Both drain rounds ran, and the caller learned that teardown did not finish.
    check res.isErr()
    check elapsed >= 2 * RecycleTimeout
    check elapsed < RecycleWaitTimeout
    # The handler still runs, so the failed recycle must not have answered for it.
    check not waitReplyQueued(ctx, 0)
    check not ctx[].myLib.isNil()

    # The failure is terminal, so the wedged slot answers every later caller the same way.
    check RecycleLibFFIPool.recycleFFIContext(ctx).isErr()

    var rejected = cborEncode(RecyclelibOpenReq(req: OpenReq(name: "after-failure")))
    var rejectedId: uint64
    check recyclelib_open(
      ctx.ffiToken(), encodedPtr(rejected), rejected.len.csize_t, addr rejectedId
    ) == RET_ERR
    check "being recycled" in $recyclelib_last_error()

    # The slot stays claimed: handing it to a new owner is what the failed drain
    # rules out.
    let other = RecycleLibFFIPool.createFFIContext().get()
    check other != ctx
    check RecycleLibFFIPool.recycleFFIContext(other).isOk()

    # The quarantined slot still hands out the one reply it owes, then says why it closed.
    gHold.store(false)
    check waitReplyQueued(ctx)
    let reply = pollMsg(ctx)
    check reply.kind == MsgReply
    check reply.id == blockReqId
    check reply.retCode == RET_OK
    let closed = pollMsg(ctx)
    check closed.ret == RET_CLOSED
    check closed.retCode == RET_ERR
    check closed.payload.len > 0
