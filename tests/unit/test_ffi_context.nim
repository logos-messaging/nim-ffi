import std/[locks, options, strutils, os, atomics]
import unittest2
import results
import ffi

type TestLib = object

type CallbackData = object
  lock: Lock
  cond: Cond
  called: bool
  callCount: int
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
  # A progress ping is not a terminal answer; skip it here.
  if retCode == RET_STALE_WARN:
    return
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].retCode = retCode
  let n = min(int(len), d[].msg.len)
  if n > 0 and not msg.isNil:
    copyMem(addr d[].msg[0], msg, n)
  d[].msgLen = n
  d[].called = true
  inc d[].callCount
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

# Global, as declareLibrary emits it: a static ctx's threads may outlive any scope.
# One pool for every slot-accounting case below — under refc a destroyed context
# can't close its five ThreadSignalPtrs, so a second 32-slot fill would put the
# suite over the 1024-fd limit.
var staticPool: FFIContextPool[TestLib]

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

  # Each static case tears its pool back down on every exit path: left running
  # under refc the threads race later suites' allocation and GC (macOS SIGSEGV).
  test "staticFFIContext returns one shared context and refuses destruction":
    defer:
      check staticPool.destroyStaticFFIContext().isOk()
    let first = staticPool.staticFFIContext().valueOr:
      assert false, "staticFFIContext failed: " & $error
      return
    check staticPool.staticFFIContext().tryGet() == first
    # Occupies a pool slot like any other context.
    check staticPool.isValidCtx(first)
    check staticPool.destroyFFIContext(first).isErr()
    # Still live, and still the same context.
    check staticPool.staticFFIContext().tryGet() == first

  test "pool exhaustion errors and leaves staticFFIContext retryable":
    var filler: seq[ptr FFIContext[TestLib]]
    defer:
      check staticPool.destroyStaticFFIContext().isOk()
      for c in filler:
        check staticPool.destroyFFIContext(c).isOk()

    check staticPool.staticFFIContext().isOk()
    var c = staticPool.createFFIContext()
    while c.isOk():
      filler.add(c.tryGet())
      c = staticPool.createFFIContext()
    # The static ctx holds a slot, so only MaxFFIContexts-1 were left.
    check filler.len == MaxFFIContexts - 1
    check staticPool.createFFIContext().isErr()

    # Hand the static ctx's slot straight to a plain one, so the retry below has
    # to fail on a genuinely full pool.
    check staticPool.destroyStaticFFIContext().isOk()
    let reclaimed = staticPool.createFFIContext().valueOr:
      assert false, "createFFIContext(pool) failed on the freed static slot: " & $error
      return
    filler.add(reclaimed)
    # No slot free: the create fails and must reset the state, not latch it.
    check staticPool.staticFFIContext().isErr()
    check staticPool.destroyFFIContext(filler.pop()).isOk()
    check staticPool.staticFFIContext().isOk()

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
    defer:
      deinitCallbackData(d)

    check sendRequestToFFIThread(ctx, SlowRequest.ffiNewReq(testCallback, addr d)).isOk()

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

    check sendRequestToFFIThread(ctx, SyncBlockingRequest.ffiNewReq(testCallback, d))
      .isOk()

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
    defer:
      deinitCallbackData(d)

    check sendRequestToFFIThread(
      ctx, HeavyRefAllocRequest.ffiNewReq(testCallback, addr d)
    )
      .isOk()
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

type SimpleLib = object
  value: int

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libtestlibNimMain(void) {}".}

declareLibrary("testlib", SimpleLib)

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
  let addrStr = cborDecode(bytes, string).valueOr:
    return 0
  cast[uint](parseBiggestUInt(addrStr))

suite "ffiCtor macro":
  test "creates context and returns pointer via callback":
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var cfg = cborEncode(TestlibCreateCtorReq(config: SimpleConfig(initialValue: 42)))
    let ret = testlib_create(encodedPtr(cfg), cfg.len.csize_t, testCallback, addr d)

    check not ret.isNil()

    waitCallback(d)
    check d.retCode == RET_OK

    let ctxAddr = ctorAddrFromCbor(callbackBytes(d))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)

    check not ctx[].myLib.isNil
    check ctx[].myLib[].value == 42

    check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

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
    defer:
      deinitCallbackData(ctorD)

    var cfg = cborEncode(TestlibCreateCtorReq(config: SimpleConfig(initialValue: 7)))
    let ctorRet =
      testlib_create(encodedPtr(cfg), cfg.len.csize_t, testCallback, addr ctorD)
    check not ctorRet.isNil()

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let ctxAddr = ctorAddrFromCbor(callbackBytes(ctorD))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer:
      check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var reqBytes = cborEncode(TestlibSendReq(cfg: SendConfig(message: "hello")))
    let ret = testlib_send(
      ctx, testCallback, addr d, encodedPtr(reqBytes), reqBytes.len.csize_t
    )
    check ret == RET_OK

    waitCallback(d)
    check d.retCode == RET_OK

    check cborDecode(callbackBytes(d), string).value == "echo:hello:7"

proc testlib_version*(lib: SimpleLib): Future[Result[string, string]] {.ffi.} =
  return ok("v" & $lib.value)

suite "sync-body .ffi. is dispatched on FFI thread":
  ## All `.ffi.` procs go through the FFI thread, even sync bodies (PR #23).
  test "sync body still produces correct payload via callback":
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer:
      deinitCallbackData(ctorD)

    var cfg = cborEncode(TestlibCreateCtorReq(config: SimpleConfig(initialValue: 3)))
    let ctorRet =
      testlib_create(encodedPtr(cfg), cfg.len.csize_t, testCallback, addr ctorD)
    check not ctorRet.isNil()

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let ctxAddr = ctorAddrFromCbor(callbackBytes(ctorD))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer:
      check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    var d2: CallbackData
    initCallbackData(d2)
    defer:
      deinitCallbackData(d2)

    var emptyBytes = cborEncode(TestlibVersionReq())
    let ret = testlib_version(
      ctx, testCallback, addr d2, encodedPtr(emptyBytes), emptyBytes.len.csize_t
    )
    check ret == RET_OK
    waitCallback(d2)
    check d2.retCode == RET_OK
    check cborDecode(callbackBytes(d2), string).value == "v3"

suite "Nim-native .ffi. / .ffiCtor. API":
  test "user proc names retain their declared Future[Result[T,string]] shape":
    let lib = SimpleLib(value: 9)
    let echoed = waitFor testlib_send(lib, SendConfig(message: "direct"))
    check echoed.isOk
    check echoed.value == "echo:direct:9"

    let v = waitFor testlib_version(lib)
    check v.isOk
    check v.value == "v9"

    let ctorRes = waitFor testlib_create(SimpleConfig(initialValue: 21))
    check ctorRes.isOk
    check ctorRes.value.value == 21

# Records getThreadId() to prove a sync `.ffi.` body runs on the FFI thread.
var gRecordedHandlerTid: Atomic[int]

type RecordTidReq {.ffi.} = object
  dummy: int

proc testlib_record_tid*(
    lib: SimpleLib, req: RecordTidReq
): Future[Result[int, string]] {.ffi.} =
  let tid = getThreadId()
  gRecordedHandlerTid.store(tid)
  return ok(tid)

suite "sync-body .ffi. runs on FFI thread (PR #23 regression)":
  test "handler thread id differs from caller's":
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer:
      deinitCallbackData(ctorD)

    var cfg = cborEncode(TestlibCreateCtorReq(config: SimpleConfig(initialValue: 0)))
    let ctorRet =
      testlib_create(encodedPtr(cfg), cfg.len.csize_t, testCallback, addr ctorD)
    check not ctorRet.isNil()
    waitCallback(ctorD)
    check ctorD.retCode == RET_OK
    let ctxAddr = ctorAddrFromCbor(callbackBytes(ctorD))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer:
      check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    gRecordedHandlerTid.store(0)
    let callerTid = getThreadId()

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    var reqBytes = cborEncode(TestlibRecordTidReq(req: RecordTidReq(dummy: 1)))
    let ret = testlib_record_tid(
      ctx, testCallback, addr d, encodedPtr(reqBytes), reqBytes.len.csize_t
    )
    check ret == RET_OK
    waitCallback(d)
    check d.retCode == RET_OK

    let handlerTid = gRecordedHandlerTid.load()
    check handlerTid != 0
    check handlerTid != callerTid
    check cborDecode(callbackBytes(d), int).value == handlerTid

# Reentrancy guard: a handler re-dispatching gets an Err, not a deadlock.
var gReentrantNestedRes: Channel[string]
gReentrantNestedRes.open()

registerReqFFI(ReentrantTriggerReq, lib: ptr TestLib):
  proc(ctxAddr: int): Future[Result[string, string]] {.async.} =
    let ctx = cast[ptr FFIContext[TestLib]](cast[uint](ctxAddr))
    var nestedD: CallbackData
    initCallbackData(nestedD)
    defer:
      deinitCallbackData(nestedD)
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
    defer:
      discard pool.destroyFFIContext(ctx)

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    let ctxAddrInt = cast[int](cast[uint](ctx))
    check sendRequestToFFIThread(
      ctx, ReentrantTriggerReq.ffiNewReq(testCallback, addr d, ctxAddrInt)
    )
      .isOk()

    waitCallback(d)
    check d.retCode == RET_OK
    check cborDecode(callbackBytes(d), string).value == "guard-fired"

    let nestedMsg = gReentrantNestedRes.recv()
    check nestedMsg.startsWith("err:")
    check "reentrant ffi call" in nestedMsg

# RET_STALE_WARN pings every ctx.staleWarnInterval, then one terminal result.
type StaleConfig {.ffi.} = object
  dummy: int

proc testlib_slow_stale*(
    lib: SimpleLib, cfg: StaleConfig
): Future[Result[string, string]] {.ffi.} =
  await sleepAsync(350.milliseconds)
  return ok("slow-stale-done")

proc createSimpleCtx(): ptr FFIContext[SimpleLib] =
  var ctorD: CallbackData
  initCallbackData(ctorD)
  defer:
    deinitCallbackData(ctorD)
  var cfg = cborEncode(TestlibCreateCtorReq(config: SimpleConfig(initialValue: 1)))
  let ctorRet =
    testlib_create(encodedPtr(cfg), cfg.len.csize_t, testCallback, addr ctorD)
  if ctorRet.isNil():
    return nil
  waitCallback(ctorD)
  if ctorD.retCode != RET_OK:
    return nil
  let ctxAddr = ctorAddrFromCbor(callbackBytes(ctorD))
  if ctxAddr == 0:
    return nil
  cast[ptr FFIContext[SimpleLib]](ctxAddr)

## Keeps stale pings apart from the one terminal answer so a test can assert both.
type StaleData = object
  lock: Lock
  cond: Cond
  staleCount: int
  lastElapsed: string
  terminalDone: bool
  terminalRet: cint
  terminalBytes: seq[byte]

proc initStaleData(d: var StaleData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitStaleData(d: var StaleData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

proc staleCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr StaleData](userData)
  let n = int(len)
  acquire(d[].lock)
  if retCode == RET_STALE_WARN:
    var s = newString(n)
    if n > 0 and not msg.isNil:
      copyMem(addr s[0], msg, n)
    inc d[].staleCount
    d[].lastElapsed = s
  else:
    var b = newSeq[byte](n)
    if n > 0 and not msg.isNil:
      copyMem(addr b[0], msg, n)
    d[].terminalRet = retCode
    d[].terminalBytes = b
    d[].terminalDone = true
    signal(d[].cond)
  release(d[].lock)

proc waitTerminal(d: var StaleData) =
  acquire(d.lock)
  while not d.terminalDone:
    wait(d.cond, d.lock)
  release(d.lock)

suite "non-terminal RET_STALE_WARN progress signal":
  test "a slow handler pings the caller, then delivers one terminal RET_OK":
    let ctx = createSimpleCtx()
    check not ctx.isNil()
    defer:
      check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    ctx.staleWarnInterval = 80.milliseconds

    var d: StaleData
    initStaleData(d)
    defer:
      deinitStaleData(d)

    var reqBytes = cborEncode(TestlibSlowStaleReq(cfg: StaleConfig(dummy: 0)))
    let ret = testlib_slow_stale(
      ctx, staleCallback, addr d, encodedPtr(reqBytes), reqBytes.len.csize_t
    )
    check ret == RET_OK

    waitTerminal(d)

    check d.staleCount >= 2
    check parseInt(d.lastElapsed) == d.staleCount * 80

    check d.terminalRet == RET_OK
    check cborDecode(d.terminalBytes, string).value == "slow-stale-done"

    let staleAtTerminal = d.staleCount
    os.sleep(200)
    check d.staleCount == staleAtTerminal
