## Tests for the CBOR-style FFI event dispatch path:
##   - `dispatchFFIEvent` accepts both `string` and `seq[byte]` bodies
##   - `dispatchFFIEventCbor` wraps a typed payload in `EventEnvelope[T]`,
##     CBOR-encodes it, and dispatches via the event callback
##
## Tests run end-to-end against a real FFI thread (via FFIContextPool +
## sendRequestToFFIThread) so we exercise the threadvar-backed
## ffiCurrentCallbackState wiring, not just the templates in isolation.

import std/[locks]
import unittest2
import results
import ffi

type TestEvtLib = object

## Event payload type (would be `{.ffi.}` in production so the codec gen
## emits a matching struct on the foreign side; the test only needs CBOR
## round-trip, which `cborEncode`/`cborDecode` provide via cbor_serial's
## generic overloads).
type MessageSentBody* {.ffi.} = object
  requestId*: string
  messageHash*: string

## Same callback-state helper as test_ffi_context.nim, duplicated here so
## this file stays a self-contained test binary.
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

proc captureCb(
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

## A request that dispatches a typed CBOR event from inside the FFI
## thread and then returns ok — so the response callback can be used to
## synchronize the test.
registerReqFFI(EmitCborEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEventCbor(
      "message_sent",
      MessageSentBody(requestId: "req-1", messageHash: "0xdeadbeef"),
    )
    return ok("emitted")

## A request that uses the lower-level `dispatchFFIEvent` with a raw
## `seq[byte]` body — the path that previously rejected non-string bodies.
registerReqFFI(EmitRawBytesEventRequest, lib: ptr TestEvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    dispatchFFIEvent("raw_bytes"):
      @[byte 0x01, 0x02, 0x03]
    return ok("emitted")

suite "dispatchFFIEventCbor":
  test "delivers EventEnvelope-shaped CBOR payload to event callback":
    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var evt: CallbackData
    initCallbackData(evt)
    defer:
      deinitCallbackData(evt)

    # Register the event callback by writing the state directly — the
    # codegen-emitted `{libname}_set_event_callback` does the same.
    ctx[].callbackState.callback = cast[pointer](captureCb)
    ctx[].callbackState.userData = addr evt

    # Trigger the dispatch from the FFI thread; the response callback is
    # ignored (we only care that the request completed so we know the event
    # has fired).
    var rsp: CallbackData
    initCallbackData(rsp)
    defer:
      deinitCallbackData(rsp)

    check sendRequestToFFIThread(
      ctx, EmitCborEventRequest.ffiNewReq(captureCb, addr rsp)
    )
      .isOk()
    waitCallback(rsp)
    waitCallback(evt)

    check evt.retCode == RET_OK
    let decoded = cborDecode(callbackBytes(evt), EventEnvelope[MessageSentBody])
    check decoded.isOk()
    check decoded.value.eventType == "message_sent"
    check decoded.value.payload.requestId == "req-1"
    check decoded.value.payload.messageHash == "0xdeadbeef"

suite "dispatchFFIEvent with seq[byte]":
  test "accepts a raw seq[byte] body":
    var pool: FFIContextPool[TestEvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var evt: CallbackData
    initCallbackData(evt)
    defer:
      deinitCallbackData(evt)

    ctx[].callbackState.callback = cast[pointer](captureCb)
    ctx[].callbackState.userData = addr evt

    var rsp: CallbackData
    initCallbackData(rsp)
    defer:
      deinitCallbackData(rsp)

    check sendRequestToFFIThread(
      ctx, EmitRawBytesEventRequest.ffiNewReq(captureCb, addr rsp)
    )
      .isOk()
    waitCallback(rsp)
    waitCallback(evt)

    check evt.retCode == RET_OK
    check callbackBytes(evt) == @[byte 0x01, 0x02, 0x03]
