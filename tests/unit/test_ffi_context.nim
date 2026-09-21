import std/[locks, options, strutils, os, atomics]
import unittest2
import results
import ffi
import ./helpers

type TestLib = object

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

registerReqFFI(BytesReplyRequest, lib: ptr TestLib):
  proc(): Future[Result[seq[byte], string]] {.async.} =
    return ok(@[0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8])

registerReqFFI(EmptyBytesReplyRequest, lib: ptr TestLib):
  proc(): Future[Result[seq[byte], string]] {.async.} =
    return ok(newSeq[byte]())

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
    check staticPool.isValidCtx(first.ffiToken())
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
    let ctx = pool.createFFIContext().valueOr:
      assert false, "createFFIContext(pool) failed: " & $error
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    check call(ctx, PingRequest.ffiNewReq("pool".cstring)).okString() == "pong:pool"

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

    check sendRequestToFFIThread(ctx, SlowRequest.ffiNewReq()).isOk()

    let t0 = Moment.now()
    check pool.destroyFFIContext(ctx).isOk()
    check (Moment.now() - t0) < 2.seconds

suite "destroyFFIContext does not hang when event loop is blocked":
  test "destroy while sync-blocking request is in-flight":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return

    check sendRequestToFFIThread(ctx, SyncBlockingRequest.ffiNewReq()).isOk()

    discard gSyncBlockStarted.recv()

    let t0 = Moment.now()
    check pool.destroyFFIContext(ctx).isErr()
    check (Moment.now() - t0) < 3.seconds

    # `pool` is a local: the leaked thread must be done with it before the test returns.
    check waitReplyQueued(ctx, 10_000)
    os.sleep(200)

suite "destroyFFIContext refc workaround":
  test "destroy after heavy ref-allocation workload returns promptly":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return

    check call(ctx, HeavyRefAllocRequest.ffiNewReq(), 30_000).okString() == "heavy-done"

    let t0 = Moment.now()
    check pool.destroyFFIContext(ctx).isOk()
    check (Moment.now() - t0) < 3.seconds

suite "sendRequestToFFIThread":
  test "a successful request gets a RET_OK reply carrying its id":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    let reqId = sendRequestToFFIThread(ctx, PingRequest.ffiNewReq("hello".cstring)).valueOr:
      check false
      return
    check reqId != 0
    let reply = nextMsg(ctx)
    check reply.ret == RET_OK
    check reply.kind == MsgReply
    check reply.id == reqId
    check reply.okString() == "pong:hello"
    # Exactly one reply per accepted request.
    check nextMsg(ctx, 100).ret == RET_TIMEOUT

  test "a failing request gets a RET_ERR reply whose payload is the error text":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    let reply = call(ctx, FailRequest.ffiNewReq())
    check reply.ret == RET_OK
    check reply.retCode == RET_ERR
    check reply.text() == "intentional failure"

  test "seq[byte] result rides as a CBOR byte string, not raw bytes":
    # A `seq[byte]` return must be CBOR, the same as every other reply. The C,
    # C++ and Rust decoders call `nimffi_dec_bytes` on the payload. They reject
    # a raw reply with the error "value encoded in non-canonical form".
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    let got = call(ctx, BytesReplyRequest.ffiNewReq())
    check got.retCode == RET_OK
    let reply = got.payload
    # The wire contract is a CBOR byte-string header (major type 2, 0x40..0x5b),
    # and then the 4 payload bytes.
    check reply.len == 5
    check reply[0] == 0x44'u8
    check cborDecode(reply, seq[byte]).value == @[0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8]

  test "empty seq[byte] result rides as an empty CBOR byte string":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    let got = call(ctx, EmptyBytesReplyRequest.ffiNewReq())
    check got.retCode == RET_OK
    let reply = got.payload
    check reply == @[0x40'u8] # byte string, length 0
    check cborDecode(reply, seq[byte]).value.len == 0

  test "an empty ok string is still a CBOR value, never an empty payload":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    let reply = call(ctx, EmptyOkRequest.ffiNewReq())
    check reply.retCode == RET_OK
    check reply.payload == @[0x60'u8] # text string, length 0
    check reply.okString() == ""

  test "sequential requests are all processed":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var lastId = 0'u64
    for i in 1 .. 5:
      let msg = "msg" & $i
      let reply = call(ctx, PingRequest.ffiNewReq(msg.cstring))
      check reply.okString() == "pong:" & msg
      check reply.id > lastId
      lastId = reply.id

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

proc createSimpleCtx(initialValue: int): ptr FFIContext[SimpleLib] =
  ## The ctor hands the token back at once; its outcome is a reply on the new context.
  var cfg =
    cborEncode(TestlibCreateCtorReq(config: SimpleConfig(initialValue: initialValue)))
  var token: FFICtxToken
  var reqId: uint64
  if testlib_create(encodedPtr(cfg), cfg.len.csize_t, addr token, addr reqId) != RET_OK:
    return nil
  let ctx = SimpleLibFFIPool.resolveCtx(token)
  if ctx.isNil() or pollReply(ctx, reqId).retCode != RET_OK:
    return nil
  return ctx

suite "ffiCtor macro":
  test "returns the token at once and the outcome as a reply on the new context":
    var cfg = cborEncode(TestlibCreateCtorReq(config: SimpleConfig(initialValue: 42)))
    var token: FFICtxToken
    var reqId: uint64
    check testlib_create(encodedPtr(cfg), cfg.len.csize_t, addr token, addr reqId) ==
      RET_OK
    check not token.isNil()
    check reqId != 0

    let ctx = SimpleLibFFIPool.resolveCtx(token)
    check not ctx.isNil()
    let reply = nextMsg(ctx)
    check reply.kind == MsgReply
    check reply.id == reqId
    check reply.retCode == RET_OK
    # The token already came back through `ctx_out`; the reply carries no value.
    check reply.payload == @[CborNullByte]

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
  test "sends request and gets the serialized response as a reply":
    let ctx = createSimpleCtx(7)
    check not ctx.isNil()
    defer:
      check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    var reqBytes = cborEncode(TestlibSendReq(cfg: SendConfig(message: "hello")))
    var reqId: uint64
    check testlib_send(
      ctx.ffiToken(), encodedPtr(reqBytes), reqBytes.len.csize_t, addr reqId
    ) == RET_OK
    check pollReply(ctx, reqId).okString() == "echo:hello:7"

proc testlib_version*(lib: SimpleLib): Future[Result[string, string]] {.ffi.} =
  return ok("v" & $lib.value)

suite "sync-body .ffi. is dispatched on FFI thread":
  ## All `.ffi.` procs go through the FFI thread, even sync bodies (PR #23).
  test "sync body still produces the correct reply payload":
    let ctx = createSimpleCtx(3)
    check not ctx.isNil()
    defer:
      check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    var emptyBytes = cborEncode(TestlibVersionReq())
    var reqId: uint64
    check testlib_version(
      ctx.ffiToken(), encodedPtr(emptyBytes), emptyBytes.len.csize_t, addr reqId
    ) == RET_OK
    check pollReply(ctx, reqId).okString() == "v3"

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
    let ctx = createSimpleCtx(0)
    check not ctx.isNil()
    defer:
      check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    gRecordedHandlerTid.store(0)
    let callerTid = getThreadId()

    var reqBytes = cborEncode(TestlibRecordTidReq(req: RecordTidReq(dummy: 1)))
    var reqId: uint64
    check testlib_record_tid(
      ctx.ffiToken(), encodedPtr(reqBytes), reqBytes.len.csize_t, addr reqId
    ) == RET_OK
    let reply = pollReply(ctx, reqId)
    check reply.retCode == RET_OK

    let handlerTid = gRecordedHandlerTid.load()
    check handlerTid != 0
    check handlerTid != callerTid
    check cborDecode(reply.payload, int).value == handlerTid

# Reentrancy guard: a handler re-dispatching gets an Err, not a deadlock.
var gReentrantNestedRes: Channel[string]
gReentrantNestedRes.open()

registerReqFFI(ReentrantTriggerReq, lib: ptr TestLib):
  proc(ctxAddr: int): Future[Result[string, string]] {.async.} =
    let ctx = cast[ptr FFIContext[TestLib]](cast[uint](ctxAddr))
    let res = sendRequestToFFIThread(ctx, PingRequest.ffiNewReq("x".cstring))
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

    let ctxAddrInt = cast[int](cast[uint](ctx))
    check call(ctx, ReentrantTriggerReq.ffiNewReq(ctxAddrInt)).okString() ==
      "guard-fired"

    let nestedMsg = gReentrantNestedRes.recv()
    check nestedMsg.startsWith("err:")
    check "reentrant ffi call" in nestedMsg
    # The refused nested request produced no reply of its own.
    check nextMsg(ctx, 100).ret == RET_TIMEOUT

# A `MsgStaleWarn` every ctx.staleWarnInterval, then the one reply.
type StaleConfig {.ffi.} = object
  dummy: int

proc testlib_slow_stale*(
    lib: SimpleLib, cfg: StaleConfig
): Future[Result[string, string]] {.ffi.} =
  await sleepAsync(350.milliseconds)
  return ok("slow-stale-done")

suite "stale warnings are messages, not replies":
  test "a slow handler warns the host that polls, then delivers one reply":
    let ctx = createSimpleCtx(1)
    check not ctx.isNil()
    defer:
      check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    ctx.staleWarnInterval = 80.milliseconds

    var reqBytes = cborEncode(TestlibSlowStaleReq(cfg: StaleConfig(dummy: 0)))
    var reqId: uint64
    check testlib_slow_stale(
      ctx.ffiToken(), encodedPtr(reqBytes), reqBytes.len.csize_t, addr reqId
    ) == RET_OK

    # This host polls at once, so each warning is collected before the next is due.
    var staleCount = 0
    var lastElapsed = 0'u64
    var reply: PolledMsg
    while true:
      let got = pollMsg(ctx)
      check got.ret == RET_OK
      if got.ret != RET_OK:
        break
      check got.id == reqId
      if got.kind == MsgReply:
        reply = got
        break
      check got.kind == MsgStaleWarn
      staleCount.inc()
      check got.aux > lastElapsed
      lastElapsed = got.aux

    check staleCount >= 2
    check lastElapsed == uint64(staleCount * 80)
    check reply.okString() == "slow-stale-done"

    # Nothing follows the reply.
    check pollMsg(ctx, 200).ret == RET_TIMEOUT
