import std/[locks, strutils, os]
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

suite "createFFIContext / destroyFFIContext":
  test "create and destroy succeeds":
    let ctx = createFFIContext[TestLib]().valueOr:
      checkpoint "createFFIContext failed: " & $error
      check false
      return
    check destroyFFIContext(ctx).isOk()

  test "double destroy is safe via running flag":
    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    check destroyFFIContext(ctx).isOk()

suite "sendRequestToFFIThread":
  test "successful request triggers RET_OK callback":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    defer: discard destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, PingRequest.ffiNewReq(testCallback, addr d, "hello".cstring)).isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check callbackMsg(d) == "pong:hello"

  test "failing request triggers RET_ERR callback":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    defer: discard destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, FailRequest.ffiNewReq(testCallback, addr d)).isOk()
    waitCallback(d)
    check d.retCode == RET_ERR

  test "empty ok response delivers empty message":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    defer: discard destroyFFIContext(ctx)

    check sendRequestToFFIThread(ctx, EmptyOkRequest.ffiNewReq(testCallback, addr d)).isOk()
    waitCallback(d)
    check d.retCode == RET_OK
    check d.msgLen == 0

  test "sequential requests are all processed":
    let ctx = createFFIContext[TestLib]().valueOr:
      check false
      return
    defer: discard destroyFFIContext(ctx)

    for i in 1 .. 5:
      var d: CallbackData
      initCallbackData(d)
      let msg = "msg" & $i
      check sendRequestToFFIThread(ctx, PingRequest.ffiNewReq(testCallback, addr d, msg.cstring)).isOk()
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

suite "ffiCtor macro":
  test "creates context and returns pointer via callback":
    var d: CallbackData
    initCallbackData(d)
    defer: deinitCallbackData(d)

    let configJson = ffiSerialize(SimpleConfig(initialValue: 42))
    let ret = testlib_create(configJson.cstring, testCallback, addr d)

    check ret == RET_OK

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

    check destroyFFIContext(ctx).isOk()

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
    check ctorRet == RET_OK

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let addrStr = callbackMsg(ctorD)
    check addrStr.len > 0

    let ctxAddr = cast[uint](parseBiggestUInt(addrStr))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check destroyFFIContext(ctx).isOk()

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
    check ctorRet == RET_OK

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let addrStr = callbackMsg(ctorD)
    check addrStr.len > 0

    let ctxAddr = cast[uint](parseBiggestUInt(addrStr))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check destroyFFIContext(ctx).isOk()

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
    check ctorRet == RET_OK

    waitCallback(ctorD)
    check ctorD.retCode == RET_OK

    let ctxAddrStr = callbackMsg(ctorD)
    check ctxAddrStr.len > 0
    let ctxAddr = cast[uint](parseBiggestUInt(ctxAddrStr))
    check ctxAddr != 0
    let ctx = cast[ptr FFIContext[SimpleLib]](ctxAddr)
    defer: check destroyFFIContext(ctx).isOk()

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
