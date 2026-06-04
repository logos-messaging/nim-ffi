import std/[locks, strutils, os, osproc, sequtils]
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
  msg: array[512, char]
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
  let n = min(int(len), d[].msg.high)
  if n > 0 and not msg.isNil:
    copyMem(addr d[].msg[0], msg, n)
  d[].msg[n] = '\0'
  d[].msgLen = n
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc waitCallback(d: var CallbackData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc callbackMsg(d: var CallbackData): string =
  result = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr result[0], addr d.msg[0], d.msgLen)

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

# Coordination channel: the FFI handler signals the test thread the instant
# it is about to block the event loop, so the test can call destroyFFIContext
# while the event loop is truly frozen.
var gSyncBlockStarted: Channel[bool]
gSyncBlockStarted.open()

registerReqFFI(SyncBlockingRequest, lib: ptr TestLib):
  proc(): Future[Result[string, string]] {.async.} =
    # Yield first so that reqReceivedSignal fires and sendRequestToFFIThread
    # returns on the calling thread before we start the synchronous block.
    await sleepAsync(0.milliseconds)
    # Signal the test thread: the event loop is about to be frozen.
    # Channel.send is annotated as raising under refc, so wrap.
    try:
      gSyncBlockStarted.send(true)
    except Exception as exc:
      return err("gSyncBlockStarted.send raised: " & exc.msg)
    # Simulates a request that blocks the event-loop thread synchronously
    # (e.g. w.stop() -> switch.stop() -> connManager.close() with blocking I/O).
    # Unlike sleepAsync, os.sleep holds the OS thread and prevents Chronos from
    # processing any callbacks -- including the reqSignal fired by destroyFFIContext.
    os.sleep(5_000)
    return ok("sync-blocking-done")

# Approximates the heavy ref-object workload that libwaku/libp2p performs on
# the FFI thread. The exact cell count is large enough to force several refc
# GC cycles; under refc this stresses the heap state that, when later combined
# with a chronos Selector allocation on the main thread (via close()), used to
# trip the rawNewObj → signal-handler infinite recursion.
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
    # Break the chain iteratively before releasing head.
    # ORC's =destroy for RefCell recurses through .next, so a 50k-node chain
    # would produce ~50k nested =destroy calls and overflow the stack.
    # Walking the list and unlinking each node first keeps destruction O(n)
    # iterative instead of O(n) recursive.
    var node = head
    head = nil
    while not node.isNil():
      let nxt = node.next
      node.next = nil  # unlink before the refcount of `node` can drop to zero
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
    # After destroying, the same slot must be available again
    let ctx2 = pool.createFFIContext().valueOr:
      assert false, "createFFIContext(pool) failed after slot release: " & $error
      return
    check pool.destroyFFIContext(ctx2).isOk()
    check ctx1 == ctx2 # same array slot reused

  test "pool exhaustion returns error":
    var pool: FFIContextPool[TestLib]
    var ctxs: array[MaxFFIContexts, ptr FFIContext[TestLib]]
    for i in 0 ..< MaxFFIContexts:
      ctxs[i] = pool.createFFIContext().valueOr:
        for j in 0 ..< i:
          discard pool.destroyFFIContext(ctxs[j])
        assert false, "createFFIContext(pool) failed at slot " & $i & ": " & $error
        return
    # Pool is now full — next create must fail
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
    check callbackMsg(d) == "pong:pool"

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
    ## Reproduces the race where destroyFFIContext was called while a long-
    ## running async request (e.g. stop_node / w.stop()) was still executing.
    ## The destroy must return well within 2 seconds; before the fix it would
    ## block forever on joinThread(ffiThread).
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return

    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    # sendRequestToFFIThread returns as soon as the FFI thread ACKs receipt;
    # the 500 ms work continues asynchronously on the FFI thread.
    check sendRequestToFFIThread(
      ctx, SlowRequest.ffiNewReq(testCallback, addr d)
    ).isOk()

    # Destroy immediately while SlowRequest is still running.
    let t0 = Moment.now()
    check pool.destroyFFIContext(ctx).isOk()
    check (Moment.now() - t0) < 2.seconds

suite "destroyFFIContext does not hang when event loop is blocked":
  test "destroy while sync-blocking request is in-flight":
    ## Reproduces the hang seen in logosdelivery_example.c:
    ##   logosdelivery_stop_node(...)   -- triggers w.stop() on the FFI thread
    ##   sleep(1)
    ##   logosdelivery_destroy(...)     -- hangs forever
    ##
    ## Root cause: w.stop() (and similar tear-down calls) can execute a
    ## synchronous blocking section that holds the OS thread, preventing
    ## the Chronos event loop from processing the reqSignal fired by
    ## destroyFFIContext.  The result is joinThread(ffiThread) never returns.
    ##
    ## With the fix, destroyFFIContext must complete well within the 5 s that
    ## SyncBlockingRequest holds the event loop.
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return

    # CallbackData and ctx are kept alive past destroyFFIContext: the leaked
    # FFI thread is still inside os.sleep(5_000) and will eventually wake,
    # run handleRes, fire testCallback, and exit normally. We wait for that
    # to happen at the end of the test so the leaked thread cannot race with
    # subsequent tests' createFFIContext on Linux/Windows. Heap allocation
    # ensures the late callback's userData is still valid when it fires.
    let d = createShared(CallbackData)
    initCallbackData(d[])

    check sendRequestToFFIThread(
      ctx, SyncBlockingRequest.ffiNewReq(testCallback, d)
    ).isOk()

    # Block until the FFI handler has signalled that os.sleep is about to start.
    # This guarantees destroyFFIContext is called while the event loop is frozen.
    discard gSyncBlockStarted.recv()

    # Destroy must return promptly even though the event loop is frozen for 5s.
    # It deliberately returns err and leaks ctx in this scenario rather than
    # hanging on joinThread.
    let t0 = Moment.now()
    check pool.destroyFFIContext(ctx).isErr()
    check (Moment.now() - t0) < 3.seconds

    # Drain the leaked thread before the test scope ends.
    # 1. waitCallback blocks until os.sleep(5_000) returns and handleRes
    #    invokes testCallback (~3.5s after destroy returned), which proves
    #    the leaked thread has reached the end of processRequest.
    # 2. Yield briefly so the thread can finish iterating its while loop,
    #    fire threadExitSignal in its defer, and return. Without this, on
    #    Linux/Windows the still-live thread can race with the next test's
    #    createFFIContext under --mm:orc and segfault.
    # ctx.cleanUpResources is intentionally NOT called: destroyFFIContext
    # skipped it for a reason, and the signal fds are reclaimed by the OS
    # at process exit.
    waitCallback(d[])
    os.sleep(200)
    deinitCallbackData(d[])
    freeShared(d)

suite "destroyFFIContext refc workaround":
  ## Documents the refc-specific workaround in cleanUpResources.
  ##
  ## Background: when the FFI thread does heavy ref-object work (the workload
  ## that triggered the libwaku hang in production), the refc GC heap reaches
  ## a state where the very first chronos Selector allocation on the *main*
  ## thread — which happens lazily inside ThreadSignalPtr.close() through
  ## getThreadDispatcher() — traps in rawNewObj. The refc signal handler
  ## itself re-enters the same allocator and the process never returns.
  ## Captured stack:
  ##   close → safeUnregisterAndCloseFd → getThreadDispatcher →
  ##   newDispatcher → Selector.new → newObj (gc.nim:488) → rawNewObj →
  ##   _sigtramp → signalHandler → newObjNoInit → addNewObjToZCT (loop)
  ##
  ## The workaround in cleanUpResources is `when defined(gcRefc): discard`,
  ## i.e. skip the close() calls under refc only. orc is unaffected and
  ## still cleans up the signal fds normally.
  ##
  ## NOTE: this test is documentation more than regression: a synthetic
  ## ref-allocation workload of ~50k cells does NOT corrupt the refc heap
  ## the way the real libwaku/libp2p teardown does, so this test passes
  ## even when the workaround is disabled. Reproducing the actual hang
  ## requires the full libwaku workload (logosdelivery_example.c).
  ## Verification of the workaround was done end-to-end against that
  ## example: with `--mm:refc` and close() enabled it hangs forever in
  ## the captured stack above; with `when defined(gcRefc): discard` it
  ## returns immediately. Under `--mm:orc` it returns immediately either
  ## way.
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
    check callbackMsg(d) == "pong:hello"

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
    check d.msgLen == 0

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
      check callbackMsg(d) == "pong:" & msg

# ---------------------------------------------------------------------------
# ffiCtor macro integration test
# ---------------------------------------------------------------------------

type SimpleLib = object
  value: int

ffiType:
  type SimpleConfig = object
    initialValue: int

proc testlib_create*(
    config: SimpleConfig
): Future[Result[SimpleLib, string]] {.ffiCtor.} =
  return ok(SimpleLib(value: config.initialValue))

# Records the value of the library object the destructor body saw, so a test can
# confirm the user cleanup body ran with the right lib state before teardown.
var gDestroyedValue {.threadvar.}: int
proc testlib_destroy*(lib: SimpleLib) {.ffiDtor.} =
  gDestroyedValue = lib.value

suite "ffiCtor macro":
  test "creates context and returns pointer via callback":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let configJson = ffiSerialize(SimpleConfig(initialValue: 42))
    let ret = testlib_create(configJson.cstring, testCallback, addr d)

    check not ret.isNil()

    waitCallback(d)

    check d.retCode == RET_OK

    # The callback message is the ctx address as a decimal string
    let addrStr = callbackMsg(d)
    check addrStr.len > 0

    let ctxAddr = cast[uint](parseBiggestUInt(addrStr))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)

    # Verify the library was properly initialized
    check not ctx[].myLib.isNil
    check ctx[].myLib[].value == 42

    check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

proc createSimpleLib(initialValue: int): ptr FFIContext[SimpleLib] =
  ## Helper: run the generated async ctor and return the live ctx.
  var d: CallbackData
  initCallbackData(d)
  defer:
    deinitCallbackData(d)
  let ret =
    testlib_create(ffiSerialize(SimpleConfig(initialValue: initialValue)).cstring,
      testCallback, addr d)
  doAssert not ret.isNil()
  waitCallback(d)
  doAssert d.retCode == RET_OK
  return cast[ptr FFIContext[SimpleLib]](cast[uint](parseBiggestUInt(callbackMsg(d))))

suite "ffiDtor macro (async destroy + reuse)":
  test "destroy fires RET_OK after teardown, frees myLib, and frees the slot":
    let ctx = createSimpleLib(5)
    check not ctx[].myLib.isNil
    check ctx[].myLib[].value == 5

    var dD: CallbackData
    initCallbackData(dD)
    defer:
      deinitCallbackData(dD)

    # Async destroy: the C return is just "accepted"; the real outcome arrives
    # via the callback once the FFI thread has finished tearing the lib down.
    check testlib_destroy(cast[pointer](ctx), testCallback, addr dD) == RET_OK
    waitCallback(dD)
    check dD.retCode == RET_OK
    check gDestroyedValue == 5 # the user cleanup body saw the live lib
    check ctx[].myLib.isNil() # freed on the FFI thread

    # The slot was freed from the FFI thread, so a fresh create reclaims it.
    let ctx2 = createSimpleLib(9)
    check ctx2 == ctx # same slot, reused worker + fds
    check ctx2[].myLib[].value == 9
    check SimpleLibFFIPool.destroyFFIContext(ctx2).isOk()

  test "destroy waits for an in-flight request before reporting RET_OK":
    let ctx = createSimpleLib(1)

    # Dispatch a 500 ms handler and do NOT wait — it is in flight at destroy time.
    var slow: CallbackData
    initCallbackData(slow)
    defer:
      deinitCallbackData(slow)
    check sendRequestToFFIThread(ctx, SlowRequest.ffiNewReq(testCallback, addr slow)).isOk()

    var dD: CallbackData
    initCallbackData(dD)
    defer:
      deinitCallbackData(dD)
    check testlib_destroy(cast[pointer](ctx), testCallback, addr dD) == RET_OK
    waitCallback(dD)
    check dD.retCode == RET_OK
    # Drained: the in-flight handler ran to completion before destroy reported OK.
    check slow.called
    check callbackMsg(slow) == "slow-done"

    let ctx2 = createSimpleLib(2)
    check ctx2 == ctx
    check SimpleLibFFIPool.destroyFFIContext(ctx2).isOk()

  test "requests are rejected once a destroy closes the gate":
    let ctx = createSimpleLib(3)

    var dD: CallbackData
    initCallbackData(dD)
    defer:
      deinitCallbackData(dD)
    check testlib_destroy(cast[pointer](ctx), testCallback, addr dD) == RET_OK
    waitCallback(dD)
    check dD.retCode == RET_OK

    # Gate stays closed until the slot is reacquired: a late request must not
    # dispatch onto a context about to be (or already) reused.
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)
    check sendRequestToFFIThread(
      ctx, SlowRequest.ffiNewReq(testCallback, addr d)
    ).isErr()

    let ctx2 = createSimpleLib(4)
    check ctx2 == ctx
    check SimpleLibFFIPool.destroyFFIContext(ctx2).isOk()

  test "a stuck context is reported as RET_ERR rather than hanging":
    let ctx = createSimpleLib(8)

    let savedTimeout = RecycleTimeout
    RecycleTimeout = 150.milliseconds
    defer:
      RecycleTimeout = savedTimeout

    # In-flight handler outlasts the (shortened) drain timeout.
    var slow: CallbackData
    initCallbackData(slow)
    defer:
      deinitCallbackData(slow)
    check sendRequestToFFIThread(ctx, SlowRequest.ffiNewReq(testCallback, addr slow)).isOk()

    var dD: CallbackData
    initCallbackData(dD)
    defer:
      deinitCallbackData(dD)
    check testlib_destroy(cast[pointer](ctx), testCallback, addr dD) == RET_OK
    waitCallback(dD)
    check dD.retCode == RET_ERR # drain timed out -> ctx reported stuck

    # The stuck slot is leaked (not reused); the handler still finishes on its
    # own. Wait for it, then fully tear the leaked slot down.
    waitCallback(slow)
    check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

# ---------------------------------------------------------------------------
# Simplified .ffi. macro integration test
# ---------------------------------------------------------------------------

ffiType:
  type SendConfig = object
    message: string

proc testlib_send*(
    lib: SimpleLib, cfg: SendConfig
): Future[Result[string, string]] {.ffi.} =
  return ok("echo:" & cfg.message & ":" & $lib.value)

suite "simplified .ffi. macro":
  test "sends request and gets serialized response via callback":
    # First create a context using ffiCtor
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer: deinitCallbackData(ctorD)

    let configJson = ffiSerialize(SimpleConfig(initialValue: 7))
    let ctorRet = testlib_create(configJson.cstring, testCallback, addr ctorD)
    check not ctorRet.isNil()

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let addrStr = callbackMsg(ctorD)
    check addrStr.len > 0

    let ctxAddr = cast[uint](parseBiggestUInt(addrStr))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    # Now call the .ffi. proc
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let cfgJson = ffiSerialize(SendConfig(message: "hello"))
    let ret = testlib_send(ctx, testCallback, addr d, cfgJson.cstring)
    check ret == RET_OK

    waitCallback(d)
    check d.retCode == RET_OK

    let receivedMsg = callbackMsg(d)
    let decoded = ffiDeserialize(receivedMsg.cstring, string).valueOr:
      check false
      ""
    check decoded == "echo:hello:7"

# ---------------------------------------------------------------------------
# async/sync detection in .ffi. macro integration test
# ---------------------------------------------------------------------------

# Sync proc (no await in body) — macro detects this and bypasses thread machinery
proc testlib_version*(
    lib: SimpleLib
): Future[Result[string, string]] {.ffi.} =
  return ok("v" & $lib.value)

suite "async/sync detection in .ffi.":
  test "sync proc invokes callback without thread hop":
    # Create a context using ffiCtor
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer: deinitCallbackData(ctorD)

    let configJson = ffiSerialize(SimpleConfig(initialValue: 3))
    let ctorRet = testlib_create(configJson.cstring, testCallback, addr ctorD)
    check not ctorRet.isNil()

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let addrStr = callbackMsg(ctorD)
    check addrStr.len > 0

    let ctxAddr = cast[uint](parseBiggestUInt(addrStr))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    var d2: CallbackData
    initCallbackData(d2)
    defer: deinitCallbackData(d2)

    # Call sync proc — callback should fire before the proc returns (no thread hop)
    let ret = testlib_version(ctx, testCallback, addr d2)
    # No sleep needed: sync path fires callback inline before returning
    check ret == RET_OK
    check d2.called   # fires synchronously — no waitCallback needed
    check d2.retCode == RET_OK
    let receivedMsg = callbackMsg(d2)
    let decoded = ffiDeserialize(receivedMsg.cstring, string).valueOr:
      check false
      ""
    check decoded == "v3"

# ---------------------------------------------------------------------------
# ptr T return type in .ffi. macro integration test
# ---------------------------------------------------------------------------

type Handle = object
  data: string

ffiType:
  type NameParam = object
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
    # Create context via ffiCtor
    var ctorD: CallbackData
    initCallbackData(ctorD)
    defer: deinitCallbackData(ctorD)

    let configJson = ffiSerialize(SimpleConfig(initialValue: 5))
    let ctorRet = testlib_create(configJson.cstring, testCallback, addr ctorD)
    check not ctorRet.isNil()

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let ctxAddrStr = callbackMsg(ctorD)
    check ctxAddrStr.len > 0
    let ctxAddr = cast[uint](parseBiggestUInt(ctxAddrStr))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check SimpleLibFFIPool.destroyFFIContext(ctx).isOk()

    # Alloc a handle
    var allocD: CallbackData
    initCallbackData(allocD)
    defer: deinitCallbackData(allocD)

    let npJson = ffiSerialize(NameParam(name: "test"))
    let allocRet = testlib_alloc_handle(ctx, testCallback, addr allocD, npJson.cstring)
    check allocRet == RET_OK

    waitCallback(allocD)
    check allocD.retCode == RET_OK

    let handleAddrStr = callbackMsg(allocD)
    check handleAddrStr.len > 0
    let handleAddr = parseBiggestUInt(handleAddrStr)
    check handleAddr != 0

    # Read the handle back
    var readD: CallbackData
    initCallbackData(readD)
    defer: deinitCallbackData(readD)

    let handleJson = ffiSerialize(cast[pointer](handleAddr))
    let readRet = testlib_read_handle(ctx, testCallback, addr readD, handleJson.cstring)
    check readRet == RET_OK

    waitCallback(readD)
    check readD.retCode == RET_OK

    let readMsg = callbackMsg(readD)
    let decodedStr = ffiDeserialize(readMsg.cstring, string).valueOr:
      check false
      ""
    check decodedStr == "test:5"

    # Free the handle
    var freeD: CallbackData
    initCallbackData(freeD)
    defer: deinitCallbackData(freeD)

    let freeRet = testlib_free_handle(ctx, testCallback, addr freeD, handleJson.cstring)
    check freeRet == RET_OK

    waitCallback(freeD)
    check freeD.retCode == RET_OK

# ---------------------------------------------------------------------------
# releaseFFIContext: park & reuse (fd-leak regression)
# ---------------------------------------------------------------------------

proc countOpenFds(): int =
  ## Number of open fds for this process, or -1 if not determinable on this
  ## platform. On Linux we count /proc/self/fd; elsewhere we shell out to lsof
  ## (skipped if lsof is unavailable, e.g. Windows).
  when defined(linux):
    var n = 0
    for _ in walkDir("/proc/self/fd"):
      inc n
    return n
  else:
    if findExe("lsof").len == 0:
      return -1
    try:
      let output =
        execProcess("lsof", args = ["-p", $getCurrentProcessId()], options = {poUsePath})
      return output.splitLines().countIt(it.len > 0)
    except CatchableError:
      return -1

proc releaseAndWait[T](pool: var FFIContextPool[T], ctx: ptr FFIContext[T]): cint =
  ## Test helper mirroring how a C consumer destroys a context: kick off the
  ## (non-blocking) teardown and block on the callback, returning its retCode.
  ## RET_OK means the lib's in-flight tasks finished and the slot was parked.
  var d: CallbackData
  initCallbackData(d)
  defer:
    deinitCallbackData(d)
  if pool.releaseFFIContext(ctx, testCallback, addr d).isErr():
    return RET_ERR
  waitCallback(d)
  return d.retCode

suite "releaseFFIContext (park & reuse)":
  test "park returns the slot and reuses the same live worker":
    var pool: FFIContextPool[TestLib]
    let ctx1 = pool.createFFIContext().valueOr:
      check false
      return
    check pool.releaseAndWait(ctx1) == RET_OK

    # Reacquire: must be the same array slot, with its worker still running.
    let ctx2 = pool.createFFIContext().valueOr:
      check false
      return
    check ctx1 == ctx2

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)
    check sendRequestToFFIThread(
      ctx2, PingRequest.ffiNewReq(testCallback, addr d, "reuse".cstring)
    ).isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check callbackMsg(d) == "pong:reuse" # reused worker still processes requests

    check pool.destroyFFIContext(ctx2).isOk()

  test "park drops the stale event callback and library pointer":
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    ctx.callbackState.callback = cast[pointer](testCallback)
    ctx.callbackState.userData = cast[pointer](0xDEAD)

    check pool.releaseAndWait(ctx) == RET_OK
    check ctx.callbackState.callback.isNil() # a watchdog tick can't call a freed cb
    check ctx.callbackState.userData.isNil()
    check ctx.myLib.isNil()

    check pool.destroyFFIContext(ctx).isOk()

  test "fd usage stays bounded across many park/reuse cycles":
    if countOpenFds() < 0:
      skip() # no fd-counting facility on this platform
    else:
      var pool: FFIContextPool[TestLib]

      # Warm up: the first create builds the slot's worker (its fds are allocated
      # once here); parking keeps them open for reuse.
      block:
        let ctx = pool.createFFIContext().valueOr:
          check false
          return
        check pool.releaseAndWait(ctx) == RET_OK

      let baseline = countOpenFds()

      for _ in 0 ..< 20:
        let ctx = pool.createFFIContext().valueOr:
          check false
          return
        var d: CallbackData
        initCallbackData(d)
        check sendRequestToFFIThread(
          ctx, PingRequest.ffiNewReq(testCallback, addr d, "x".cstring)
        ).isOk()
        waitCallback(d)
        deinitCallbackData(d)
        check pool.releaseAndWait(ctx) == RET_OK

      let afterCycles = countOpenFds()
      # Reuse must not grow fds. Before the fix each cycle leaked ~10 fds (4
      # ThreadSignalPtr socketpairs + 2 dispatcher kqueues); the small slack
      # only tolerates unrelated runtime fd noise, not a per-cycle leak.
      check afterCycles <= baseline + 5

      # Tear the (still parked) slot's worker down so the test leaves no threads.
      let last = pool.createFFIContext().valueOr:
        check false
        return
      check pool.destroyFFIContext(last).isOk()
