## Native (zero-serialization) event delivery: a `{.ffiEvent.}` now fans out to
## both kinds of listener at once — native listeners receive the payload as a
## typed `<T>Pod` by pointer, CBOR listeners receive the `EventEnvelope` bytes.
## Mirrors the native/CBOR split already in place for requests.
##
## The CBOR side is covered more broadly in test_event_dispatch; here we pin the
## *native* path and that both fire from one dispatch. Runs under orc + refc.

import std/[locks]
import unittest2
import results
import ffi

type EvtLib = object

type NativeEvt {.ffi.} = object
  message: string
  count: int
  tags: seq[string]
  ok: bool

proc onNativeEvt(evt: NativeEvt) {.ffiEvent: "native_evt".}

proc sampleEvt(): NativeEvt =
  NativeEvt(message: "hello", count: 7, tags: @["a", "", "ccc"], ok: true)

# A request that fires the event from the FFI thread, then returns.
registerReqFFI(EmitEvtRequest, lib: ptr EvtLib):
  proc(): Future[Result[string, string]] {.async.} =
    onNativeEvt(sampleEvt())
    return ok("emitted")

# --- native listener capture (clone the typed POD off the FFI thread) -------
type NativeCap = object
  lock: Lock
  cond: Cond
  done: bool
  ret: cint
  pod: NativeEvtPod
  hasPod: bool

proc initNativeCap(c: var NativeCap) =
  c.lock.initLock()
  c.cond.initCond()
proc deinitNativeCap(c: var NativeCap) =
  c.cond.deinitCond()
  c.lock.deinitLock()
proc waitNativeCap(c: var NativeCap) =
  acquire(c.lock)
  while not c.done:
    wait(c.cond, c.lock)
  release(c.lock)

proc nativeEvtCb(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  let c = cast[ptr NativeCap](ud)
  acquire(c[].lock)
  c[].ret = ret
  if ret == RET_OK and not msg.isNil:
    # Native ABI: msg is a `ptr NativeEvtPod`; deep-copy it off the FFI thread.
    c[].pod = clonePod(cast[ptr NativeEvtPod](msg)[])
    c[].hasPod = true
  c[].done = true
  signal(c[].cond)
  release(c[].lock)

# --- CBOR listener capture --------------------------------------------------
type CborCap = object
  lock: Lock
  cond: Cond
  done: bool
  ret: cint
  msg: array[2048, byte]
  msgLen: int

proc initCborCap(c: var CborCap) =
  c.lock.initLock()
  c.cond.initCond()
proc deinitCborCap(c: var CborCap) =
  c.cond.deinitCond()
  c.lock.deinitLock()
proc waitCborCap(c: var CborCap) =
  acquire(c.lock)
  while not c.done:
    wait(c.cond, c.lock)
  release(c.lock)
proc bytes(c: var CborCap): seq[byte] =
  var b = newSeq[byte](c.msgLen)
  if c.msgLen > 0:
    copyMem(addr b[0], addr c.msg[0], c.msgLen)
  return b

proc cborEvtCb(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  let c = cast[ptr CborCap](ud)
  acquire(c[].lock)
  c[].ret = ret
  let n = min(int(len), c[].msg.len)
  if n > 0 and not msg.isNil:
    copyMem(addr c[].msg[0], msg, n)
  c[].msgLen = n
  c[].done = true
  signal(c[].cond)
  release(c[].lock)

# A throwaway response callback to know the request (and thus the dispatch) ran.
proc rspCb(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  let c = cast[ptr CborCap](ud)
  acquire(c[].lock)
  c[].done = true
  signal(c[].cond)
  release(c[].lock)

suite "native event delivery":
  test "one dispatch delivers a typed POD to native + CBOR to cbor listeners":
    var pool: FFIContextPool[EvtLib]
    let ctx = pool.createFFIContext().valueOr:
      check false
      return
    defer:
      discard pool.destroyFFIContext(ctx)

    var ncap: NativeCap
    initNativeCap(ncap)
    defer:
      deinitNativeCap(ncap)
    var ccap: CborCap
    initCborCap(ccap)
    defer:
      deinitCborCap(ccap)

    # Same event, two listeners of different formats.
    check addEventListener(
      ctx[].eventRegistry, "native_evt", nativeEvtCb, addr ncap, native = true
    ) != 0'u64
    check addEventListener(
      ctx[].eventRegistry, "native_evt", cborEvtCb, addr ccap, native = false
    ) != 0'u64

    var rsp: CborCap
    initCborCap(rsp)
    defer:
      deinitCborCap(rsp)
    check sendRequestToFFIThread(ctx, EmitEvtRequest.ffiNewReq(rspCb, addr rsp)).isOk()
    waitCborCap(rsp)
    waitNativeCap(ncap)
    waitCborCap(ccap)

    # Native listener: the typed POD round-trips to the original value.
    check ncap.ret == RET_OK
    check ncap.hasPod
    let got = podToNim(ncap.pod)
    freePod(ncap.pod)
    check got == sampleEvt()

    # CBOR listener: the EventEnvelope decodes to the same value.
    check ccap.ret == RET_OK
    let decoded = cborDecode(bytes(ccap), EventEnvelope[NativeEvt])
    check decoded.isOk()
    check decoded.value.eventType == "native_evt"
    check decoded.value.payload == sampleEvt()
