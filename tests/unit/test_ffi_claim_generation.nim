## The claim marker and the request stamp are cut from the same generation, so a
## token or a request of a past owner never reaches the next one.

import std/[atomics, os]
import unittest2
import results
import ffi
import helpers

type ClaimLib = object

registerReqFFI(NoopRequest, lib: ptr ClaimLib):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("noop")

# Module-level, as declareLibrary emits it: a recycled slot keeps its threads,
# so the pool must outlive every test that claims from it.
var gPool: FFIContextPool[ClaimLib]

var gCalls: Atomic[int]

proc countingCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  if retCode == RET_STALE_WARN:
    return
  gCalls.atomicInc()

proc waitForCalls(n: int): bool =
  for _ in 0 ..< 500:
    if gCalls.load() >= n:
      return true
    os.sleep(10)
  false

suite "claim and generation are one atomic":
  test "a claim leaves an odd generation and a token that names it":
    let ctx = gPool.createFFIContext().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    check ctx.isInUse()
    check (ctx.currentGeneration() and 1) == 1
    check ctx.ffiToken().tokenGeneration() == ctx.currentGeneration()
    check gPool.isValidCtx(ctx.ffiToken())
    check gPool.recycleFFIContext(ctx).isOk()

  test "a losing claim leaves the owner's token alive":
    let ctx = gPool.createFFIContext().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    let token = ctx.ffiToken()
    let generation = ctx.currentGeneration()
    check not ctx.tryClaim()
    check ctx.currentGeneration() == generation
    check gPool.isValidCtx(token)
    check gPool.recycleFFIContext(ctx).isOk()

  test "a released slot carries an even generation that no token names":
    let ctx = gPool.createFFIContext().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    let token = ctx.ffiToken()
    check gPool.recycleFFIContext(ctx).isOk()
    waitSlotFree(ctx)
    check not ctx.isInUse()
    check (ctx.currentGeneration() and 1) == 0
    check not gPool.isValidCtx(token)

suite "a request carries the claim it was submitted under":
  test "a stamp from another claim is rejected at the send":
    let ctx = gPool.createFFIContext().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    defer:
      check gPool.recycleFFIContext(ctx).isOk()

    gCalls.store(0)
    let staleGeneration = ctx.currentGeneration() - 2
    check sendRequestToFFIThread(
      ctx, NoopRequest.ffiNewReq(countingCallback, nil), staleGeneration
    )
      .isErr()
    # The send owns the rejection, so the callback of the past owner stays untouched.
    check gCalls.load() == 0

    check sendRequestToFFIThread(ctx, NoopRequest.ffiNewReq(countingCallback, nil)).isOk()
    check waitForCalls(1)
