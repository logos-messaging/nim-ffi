## Recycle hands the pool slot back with nothing of the previous owner left on
## it: no live handles, and no teardown at all while a handler still runs.

import std/[atomics, locks, os]
import unittest2
import results
import ffi

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

proc wasCalled(d: var CallbackData): bool =
  acquire(d.lock)
  let called = d.called
  release(d.lock)
  called

proc payload(d: var CallbackData): seq[byte] =
  var b = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr b[0], addr d.msg[0], d.msgLen)
  b

proc encodedPtr(b: var seq[byte]): ptr byte =
  if b.len == 0:
    nil
  else:
    cast[ptr byte](addr b[0])

proc waitSlotFree[T](ctx: ptr FFIContext[T]) =
  ## `requestRecycle` returns once the recycle fired its done signal, which is
  ## one step before the FFI thread releases the claim (the fire has to come
  ## first, or a thread claiming the slot would take it as its own answer). Wait
  ## that step out before a check that depends on the slot being free.
  let deadline = Moment.now() + 5.seconds
  while ctx.isInUse() and Moment.now() < deadline:
    os.sleep(1)

template runCall(d, ctx, reqBytes, exportProc) =
  initCallbackData(d)
  var rb = reqBytes
  check exportProc(ctx.ffiToken(), testCallback, addr d, encodedPtr(rb), rb.len.csize_t) ==
    RET_OK
  waitCallback(d)

# The blocked handler answers long after its test returns, so its state is a
# global: a stack copy would be gone by then.
var gBlockData: CallbackData

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

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)
    var rb = cborEncode(RecyclelibOpenReq(req: OpenReq(name: "stale")))
    check recyclelib_open(
      staleToken, testCallback, addr d, encodedPtr(rb), rb.len.csize_t
    ) == RET_ERR
    # Rejected before the enqueue: the callback carries the error, and the new
    # owner never sees the request.
    check wasCalled(d)
    check d.retCode == RET_ERR
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

    var od: CallbackData
    runCall(
      od,
      first,
      cborEncode(RecyclelibOpenReq(req: OpenReq(name: "alpha"))),
      recyclelib_open,
    )
    defer:
      deinitCallbackData(od)
    check od.retCode == RET_OK
    let handle = cborDecode(payload(od), uint64).value
    check handle == 1'u64
    check first[].handles.byHandle.len == 1

    check RecycleLibFFIPool.recycleFFIContext(first).isOk()
    waitSlotFree(first)
    check first[].handles.byHandle.len == 0

    let second = RecycleLibFFIPool.createFFIContext().get()
    # Lowest free slot wins, so a fresh slot here would prove nothing.
    check second == first

    var td: CallbackData
    runCall(td, second, cborEncode(RecyclelibTokenReq(s: handle)), recyclelib_token)
    defer:
      deinitCallbackData(td)
    check td.retCode == RET_ERR

    check RecycleLibFFIPool.recycleFFIContext(second).isOk()

  test "handles of a reused slot start from a clean table":
    let ctx = RecycleLibFFIPool.createFFIContext().get()
    for i in 0 .. 4:
      var od: CallbackData
      runCall(
        od,
        ctx,
        cborEncode(RecyclelibOpenReq(req: OpenReq(name: "s" & $i))),
        recyclelib_open,
      )
      check od.retCode == RET_OK
      deinitCallbackData(od)
    check ctx[].handles.byHandle.len == 5

    check RecycleLibFFIPool.recycleFFIContext(ctx).isOk()
    check ctx[].handles.byHandle.len == 0

suite "recycle with a handler that does not drain":
  # Leaks its slot on purpose, so it runs last in this file.
  test "the recycle reports the failure and keeps the library":
    initCallbackData(gBlockData)
    let ctx = RecycleLibFFIPool.createFFIContext().get()

    gHold.store(true)
    gEntered.store(false)
    var rb = cborEncode(RecyclelibBlockReq())
    check recyclelib_block(
      ctx.ffiToken(), testCallback, addr gBlockData, encodedPtr(rb), rb.len.csize_t
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
    # The host still owns the userData of the in-flight request, so the callback
    # it carries must not have fired yet.
    check not wasCalled(gBlockData)
    check not ctx[].myLib.isNil()

    # The failure is terminal, so the wedged slot answers every later caller the same way.
    check RecycleLibFFIPool.recycleFFIContext(ctx).isErr()

    var rd: CallbackData
    initCallbackData(rd)
    defer:
      deinitCallbackData(rd)
    var rejected = cborEncode(RecyclelibOpenReq(req: OpenReq(name: "after-failure")))
    check recyclelib_open(
      ctx.ffiToken(), testCallback, addr rd, encodedPtr(rejected), rejected.len.csize_t
    ) == RET_ERR
    check rd.retCode == RET_ERR

    # The slot stays claimed: handing it to a new owner is what the failed drain
    # rules out.
    let other = RecycleLibFFIPool.createFFIContext().get()
    check other != ctx
    check RecycleLibFFIPool.recycleFFIContext(other).isOk()

    gHold.store(false)
    waitCallback(gBlockData)
    deinitCallbackData(gBlockData)
