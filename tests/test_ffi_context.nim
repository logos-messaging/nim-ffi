import std/[locks, options, strutils, os, atomics]
import unittest2
import results
import ../ffi

type TestLib = object

## Per-request callback state.  The test thread blocks on `cond` until the
## FFI thread signals it — no polling, no CPU waste.
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

proc callbackBytes(d: var CallbackData): seq[byte] =
  var bytes = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr bytes[0], addr d.msg[0], d.msgLen)
  return bytes

proc callbackErr(d: var CallbackData): string =
  ## Reads the error payload (sent as raw UTF-8 bytes on RET_ERR).
  var msg = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr msg[0], addr d.msg[0], d.msgLen)
  return msg

registerReqFFI(PingRequest, lib: ptr TestLib):
  proc(message: cstring): Future[Result[string, string]] {.async.} =
    return ok("pong:" & $message)

registerReqFFI(FailRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    return err("intentional failure")

registerReqFFI(EmptyOkRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("")

registerReqFFI(SlowRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    await sleepAsync(500.milliseconds)
    return ok("slow-done")

var gSyncBlockStarted: Channel[bool]
gSyncBlockStarted.open()

registerReqFFI(SyncBlockingRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    await sleepAsync(0.milliseconds)
    try:
      gSyncBlockStarted.send(true)
    except Exception as exc:
      return err("gSyncBlockStarted.send raised: " & exc.msg)
    os.sleep(5_000)
    return ok("sync-blocking-done")

type RefCell = ref object
  next: RefCell
  payload: array[64, byte]

registerReqFFI(HeavyRefAllocRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    var head: RefCell
    for i in 0 ..< 50_000:
      let n = RefCell(next: head)
      head = n
      if i mod 1000 == 0:
        await sleepAsync(0.milliseconds)
    var node = head
    head = nil
    while not node.isNil():
      let nxt = node.next
      node.next = nil
      node = nxt
    await sleepAsync(10.milliseconds)
    return ok("heavy-done")

suite "FFIContextPool":
  test "create and destroy via pool succeeds":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      assert false, "createFFIContext(pool) failed: " & $error
      return
    check pool.destroyFFIContext(ctx).isOk()

  test "slot is reused after destroy":
    var pool: FFIContextPool[TestLib]
    let ctx1 = pool.createFFIContext().valueOr:
      assert false, "createFFIContext(pool) failed: " & $error
      return
    check pool.destroyFFIContext(ctx1).isOk()
    let ctx2 = pool.createFFIContext().valueOr:
      assert false, "createFFIContext(pool) failed after slot release: " & $error
      return
    check pool.destroyFFIContext(ctx2).isOk()
    check ctx1 == ctx2

  test "pool exhaustion returns error":
    var pool: FFIContextPool[TestLib]
    var ctxs: array[MaxFFIContexts, ptr FFIContext[TestLib]]
    for i in 0 ..< MaxFFIContexts:
      ctxs[i] = pool.createFFIContext().valueOr:
        for j in 0 ..< i:
          discard pool.destroyFFIContext(ctxs[j])
        assert false, "createFFIContext(pool) failed at slot " & $i & ": " & $error
        return
    check pool.createFFIContext().isErr()
    for i in 0 ..< MaxFFIContexts:
      discard pool.destroyFFIContext(ctxs[i])

  test "requests are processed via pool context":
    var pool: FFIContextPool[TestLib]
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    let ctx = pool.createFFIContext().valueOr:
      assert false, "createFFIContext(pool) failed: " & $error
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(
      ctx, PingRequest.ffiNewReq(testCallback, addr d, "pool".cstring)
    )
      .isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check cborDecode(callbackBytes(d), string).value == "pong:pool"

suite "createFFIContext / destroyFFIContext":
  test "create and destroy succeeds":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    check pool.destroyFFIContext(ctx).isOk()

  test "double destroy is safe via running flag":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    check pool.destroyFFIContext(ctx).isOk()

suite "destroyFFIContext does not hang":
  test "destroy while a slow async request is still in-flight":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return

    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    check sendRequestToFFIThread(
      ctx, SlowRequest.ffiNewReq(testCallback, addr d)
    ).isOk()

    let t0 = Moment.now()
    check pool.destroyFFIContext(ctx).isOk()
    check (Moment.now() - t0) < 2.seconds

suite "destroyFFIContext does not hang when event loop is blocked":
  test "destroy while sync-blocking request is in-flight":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return

    let d = createShared(CallbackData)
    initCallbackData(d[])

    check sendRequestToFFIThread(
      ctx, SyncBlockingRequest.ffiNewReq(testCallback, d)
    ).isOk()

    discard gSyncBlockStarted.recv()

    let t0 = Moment.now()
    check pool.destroyFFIContext(ctx).isErr()
    check (Moment.now() - t0) < 3.seconds

    waitCallback(d[])
    os.sleep(200)
    deinitCallbackData(d[])
    freeShared(d)

suite "destroyFFIContext refc workaround":
  test "destroy after heavy ref-allocation workload returns promptly":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return

    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    check sendRequestToFFIThread(
      ctx, HeavyRefAllocRequest.ffiNewReq(testCallback, addr d)
    ).isOk()
    waitCallback(d)
    check d.retCode == RET_OK

    let t0 = Moment.now()
    check pool.destroyFFIContext(ctx).isOk()
    check (Moment.now() - t0) < 3.seconds

suite "sendRequestToFFIThread":
  test "successful request triggers RET_OK callback":
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(
      ctx, PingRequest.ffiNewReq(testCallback, addr d, "hello".cstring)
    )
      .isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check cborDecode(callbackBytes(d), string).value == "pong:hello"

  test "failing request triggers RET_ERR callback":
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, FailRequest.ffiNewReq(testCallback, addr d)).isOk()
    waitCallback(d)
    check d.retCode == RET_ERR
    # Errors are raw UTF-8 — not CBOR.
    check callbackErr(d) == "intentional failure"

  test "empty ok response delivers empty message":
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, EmptyOkRequest.ffiNewReq(testCallback, addr d))
      .isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    # CBOR-encoded "" is a single byte (text string of length 0): 0x60
    check cborDecode(callbackBytes(d), string).value == ""

  test "sequential requests are all processed":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    for i in 1 .. 5:
      var d: CallbackData
      initCallbackData(d)
      let msg = "msg" & $i
      check sendRequestToFFIThread(
        ctx, PingRequest.ffiNewReq(testCallback, addr d, msg.cstring)
      )
        .isOk()
      waitCallback(d)
      deinitCallbackData(d)
      check d.retCode == RET_OK
      check cborDecode(callbackBytes(d), string).value == "pong:" & msg

# ---------------------------------------------------------------------------
# ffiCtor / .ffi. macros — exercise the full CBOR transport
# ---------------------------------------------------------------------------

type SimpleLib = object
  value: int

type SimpleConfig {.ffi.} = object
  initialValue: int

proc testlib_create*(
    config: SimpleConfig
): Future[Result[SimpleLib, string]] {.ffiCtor.} =
  return ok(SimpleLib(value: config.initialValue))

proc encodedPtr(bytes: var seq[byte]): ptr byte =
  if bytes.len == 0:
    nil
  else:
    cast[ptr byte](addr bytes[0])

proc ctorAddrFromCbor(bytes: seq[byte]): uint =
  ## The ctor success payload is a CBOR text string of the decimal address.
  let addrStr = cborDecode(bytes, string).valueOr:
    return 0
  cast[uint](parseBiggestUInt(addrStr))

suite "ffiCtor macro":
  test "creates context and returns pointer via callback":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    var cfg = cborEncode(
      TestlibCreateCtorReq(config: SimpleConfig(initialValue: 42))
    )
    let ret = testlib_create(
      encodedPtr(cfg), cfg.len.csize_t, testCallback, addr d
    )

    check not ret.isNil()

    waitCallback(d)
    check d.retCode == RET_OK

    let ctxAddr = ctorAddrFromCbor(callbackBytes(d))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)

    check not ctx[].myLib.isNil
    check ctx[].myLib[].value == 42

    check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

# ---------------------------------------------------------------------------
# Simplified .ffi. macro integration test
# ---------------------------------------------------------------------------

type SendConfig {.ffi.} = object
  message: string

proc testlib_send*(
    lib: SimpleLib, cfg: SendConfig
): Future[Result[string, string]] {.ffi.} =
  return ok("echo:" & cfg.message & ":" & $lib.value)

suite "simplified .ffi. macro":
  test "sends request and gets serialized response via callback":
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer: deinitCallbackData(ctorD)

    var cfg = cborEncode(
      TestlibCreateCtorReq(config: SimpleConfig(initialValue: 7))
    )
    let ctorRet = testlib_create(
      encodedPtr(cfg), cfg.len.csize_t, testCallback, addr ctorD
    )
    check not ctorRet.isNil()

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let ctxAddr = ctorAddrFromCbor(callbackBytes(ctorD))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    # The .ffi. macro packs all extra params into one CBOR Req struct.
    var reqBytes = cborEncode(TestlibSendReq(cfg: SendConfig(message: "hello")))
    let ret = testlib_send(
      ctx, testCallback, addr d, encodedPtr(reqBytes), reqBytes.len.csize_t
    )
    check ret == RET_OK

    waitCallback(d)
    check d.retCode == RET_OK

    check cborDecode(callbackBytes(d), string).value == "echo:hello:7"

proc testlib_version*(
    lib: SimpleLib
): Future[Result[string, string]] {.ffi.} =
  return ok("v" & $lib.value)

suite "sync-body .ffi. is dispatched on FFI thread":
  ## Before PR #23 (items 1–5), a `.ffi.` body without `await` was emitted as
  ## an inline-on-foreign-thread fast path. That was deleted; all `.ffi.`
  ## procs now go through the FFI thread. This test asserts the round-trip
  ## still produces the expected payload via the callback.
  test "sync body still produces correct payload via callback":
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer: deinitCallbackData(ctorD)

    var cfg = cborEncode(
      TestlibCreateCtorReq(config: SimpleConfig(initialValue: 3))
    )
    let ctorRet = testlib_create(
      encodedPtr(cfg), cfg.len.csize_t, testCallback, addr ctorD
    )
    check not ctorRet.isNil()

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let ctxAddr = ctorAddrFromCbor(callbackBytes(ctorD))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    var d2: CallbackData
    initCallbackData(d2)
    defer: deinitCallbackData(d2)

    # No-extra-param .ffi. proc; pack an empty Req.
    var emptyBytes = cborEncode(TestlibVersionReq())
    let ret = testlib_version(
      ctx, testCallback, addr d2, encodedPtr(emptyBytes), emptyBytes.len.csize_t
    )
    check ret == RET_OK
    waitCallback(d2) # always asynchronous now
    check d2.retCode == RET_OK
    check cborDecode(callbackBytes(d2), string).value == "v3"

# ---------------------------------------------------------------------------
# Nim-native API (no callbacks, no CBOR buffers): the original proc name
# resolves to the user's declared async signature and is callable directly.
# ---------------------------------------------------------------------------

suite "Nim-native .ffi. / .ffiCtor. API":
  test "user proc names retain their declared Future[Result[T,string]] shape":
    let lib = SimpleLib(value: 9)
    # Async {.ffi.} proc — call directly without ctx/callback dance.
    let echoed = waitFor testlib_send(lib, SendConfig(message: "direct"))
    check echoed.isOk
    check echoed.value == "echo:direct:9"

    # Sync {.ffi.} body — still typed as Future[Result[T,string]] per the
    # user's source-level declaration (b): completed-future wrapper.
    let v = waitFor testlib_version(lib)
    check v.isOk
    check v.value == "v9"

    # The ctor body is similarly callable from Nim with its declared signature.
    let ctorRes = waitFor testlib_create(SimpleConfig(initialValue: 21))
    check ctorRes.isOk
    check ctorRes.value.value == 21

# ---------------------------------------------------------------------------
# ptr T return type in .ffi.
# ---------------------------------------------------------------------------

type Handle = object
  data: string

type NameParam {.ffi.} = object
  name: string

proc testlib_alloc_handle*(
    lib: SimpleLib, np: NameParam
): Future[Result[ptr Handle, string]] {.ffi.} =
  let h = createShared(Handle)
  h[] = Handle(data: np.name & ":" & $lib.value)
  return ok(h)

proc testlib_read_handle*(
    lib: SimpleLib, handle: pointer
): Future[Result[string, string]] {.ffi.} =
  let h = cast[ptr Handle](handle)
  return ok(h[].data)

proc testlib_free_handle*(
    lib: SimpleLib, handle: pointer
): Future[Result[string, string]] {.ffi.} =
  let h = cast[ptr Handle](handle)
  deallocShared(h)
  return ok("freed")

suite "ptr return type in .ffi.":
  test "returns a heap-allocated handle and reads it back":
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer: deinitCallbackData(ctorD)

    var cfg = cborEncode(
      TestlibCreateCtorReq(config: SimpleConfig(initialValue: 5))
    )
    let ctorRet = testlib_create(
      encodedPtr(cfg), cfg.len.csize_t, testCallback, addr ctorD
    )
    check not ctorRet.isNil()

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let ctxAddr = ctorAddrFromCbor(callbackBytes(ctorD))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    var allocD: CallbackData
    initCallbackData(allocD)
    defer: deinitCallbackData(allocD)

    var allocBytes = cborEncode(
      TestlibAllocHandleReq(np: NameParam(name: "test"))
    )
    let allocRet = testlib_alloc_handle(
      ctx, testCallback, addr allocD, encodedPtr(allocBytes), allocBytes.len.csize_t
    )
    check allocRet == RET_OK

    waitCallback(allocD)
    check allocD.retCode == RET_OK

    # ptr T return: CBOR unsigned int with the address.
    let handleAddrU = cborDecode(callbackBytes(allocD), uint64).value
    check handleAddrU != 0

    var readD: CallbackData
    initCallbackData(readD)
    defer: deinitCallbackData(readD)

    var readBytes = cborEncode(
      TestlibReadHandleReq(handle: cast[pointer](handleAddrU))
    )
    let readRet = testlib_read_handle(
      ctx, testCallback, addr readD, encodedPtr(readBytes), readBytes.len.csize_t
    )
    check readRet == RET_OK

    waitCallback(readD)
    check readD.retCode == RET_OK
    check cborDecode(callbackBytes(readD), string).value == "test:5"

    var freeD: CallbackData
    initCallbackData(freeD)
    defer: deinitCallbackData(freeD)

    var freeBytes = cborEncode(
      TestlibFreeHandleReq(handle: cast[pointer](handleAddrU))
    )
    let freeRet = testlib_free_handle(
      ctx, testCallback, addr freeD, encodedPtr(freeBytes), freeBytes.len.csize_t
    )
    check freeRet == RET_OK

    waitCallback(freeD)
    check freeD.retCode == RET_OK
    check cborDecode(callbackBytes(freeD), string).value == "freed"

# ---------------------------------------------------------------------------
# Regression for PR #23 review items 1–5: a `.ffi.` body without `await`
# used to be emitted as an inline-on-foreign-thread fast path, which bypassed
# `foreignThreadGc`, `ctx.lock`, and chronos's single-thread invariant. The
# sync fast-path was deleted; this test records `getThreadId()` inside a
# sync body and asserts the handler runs on the FFI thread, not on the
# caller's thread.
# ---------------------------------------------------------------------------

var gRecordedHandlerTid: Atomic[int]

type RecordTidReq {.ffi.} = object
  dummy: int

proc testlib_record_tid*(
    lib: SimpleLib, req: RecordTidReq
): Future[Result[int, string]] {.ffi.} =
  ## Sync body — used to live on the inline fast-path; must now run on the
  ## FFI thread.
  let tid = getThreadId()
  gRecordedHandlerTid.store(tid)
  return ok(tid)

suite "sync-body .ffi. runs on FFI thread (PR #23 regression)":
  test "handler thread id differs from caller's":
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer: deinitCallbackData(ctorD)

    var cfg = cborEncode(
      TestlibCreateCtorReq(config: SimpleConfig(initialValue: 0))
    )
    let ctorRet = testlib_create(
      encodedPtr(cfg), cfg.len.csize_t, testCallback, addr ctorD
    )
    check not ctorRet.isNil()
    waitCallback(ctorD)
    check ctorD.retCode == RET_OK
    let ctxAddr = ctorAddrFromCbor(callbackBytes(ctorD))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    gRecordedHandlerTid.store(0)
    let callerTid = getThreadId()

    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    var reqBytes = cborEncode(TestlibRecordTidReq(req: RecordTidReq(dummy: 1)))
    let ret = testlib_record_tid(
      ctx, testCallback, addr d, encodedPtr(reqBytes), reqBytes.len.csize_t
    )
    check ret == RET_OK
    waitCallback(d)
    check d.retCode == RET_OK

    let handlerTid = gRecordedHandlerTid.load()
    check handlerTid != 0
    # The whole point of the fix: even a sync-body handler is dispatched off
    # the caller thread. If this fails the inline fast-path is back.
    check handlerTid != callerTid
    # And the callback payload (the recorded tid) matches what the handler stored.
    check cborDecode(callbackBytes(d), int).value == handlerTid

# ---------------------------------------------------------------------------
# Regression for PR #23 review item 6: reentrancy guard on
# sendRequestToFFIThread. A handler running on the FFI thread that tries to
# dispatch back through sendRequestToFFIThread used to self-deadlock waiting
# on `reqReceivedSignal` (which only the FFI thread can fire). The guard now
# returns an Err immediately.
# ---------------------------------------------------------------------------

var gReentrantNestedRes: Channel[string]
gReentrantNestedRes.open()

# Handler runs on the FFI thread; it nests a send back into the same ctx and
# reports the outcome through gReentrantNestedRes. Carrying the ctx address
# via the request payload sidesteps the cross-thread visibility issue of
# thread-local pointers.
registerReqFFI(ReentrantTriggerReq, lib: ptr TestLib):
  proc(ctxAddr: int): Future[Result[string, string]] {.async.} =
    let ctx = cast[ptr FFIContext[TestLib]](cast[uint](ctxAddr))
    var nestedD: CallbackData
    initCallbackData(nestedD)
    defer: deinitCallbackData(nestedD)
    let res = sendRequestToFFIThread(
      ctx, PingRequest.ffiNewReq(testCallback, addr nestedD, "x".cstring)
    )
    if res.isErr():
      try:
        gReentrantNestedRes.send("err:" & res.error)
      except Exception as exc:
        return err("channel.send raised: " & exc.msg)
      return ok("guard-fired")
    try:
      gReentrantNestedRes.send("ok-unexpected")
    except Exception as exc:
      return err("channel.send raised: " & exc.msg)
    return ok("ok-unexpected")

suite "reentrancy guard (PR #23 review, item 6)":
  test "send from inside an FFI handler returns Err instead of deadlocking":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer: discard pool.destroyFFIContext(ctx)

    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let ctxAddrInt = cast[int](cast[uint](ctx))
    check sendRequestToFFIThread(
      ctx,
      ReentrantTriggerReq.ffiNewReq(testCallback, addr d, ctxAddrInt),
    ).isOk()

    # The outer callback only fires once the handler — including its nested
    # send attempt — has finished. No polling/sleep needed.
    waitCallback(d)
    check d.retCode == RET_OK
    check cborDecode(callbackBytes(d), string).value == "guard-fired"

    let nestedMsg = gReentrantNestedRes.recv()
    check nestedMsg.startsWith("err:")
    check "reentrant ffi call" in nestedMsg
