## Exercises the CBOR-free `abi = c` non-scalar path through a real FFI thread:
## the request rides as a packed `_CWire` struct and the reply comes back as the
## response's `_CWire` image. Covers `seq`/`Option` fields, whose payload buffers
## are packed on the calling thread and freed on the FFI thread.

import std/[locks, options, strutils]
import unittest2
import results
import ffi

type WireLib = object
  tag: string

# Stub the dylib NimMain importc that declareLibrary emits (links as an exe).
{.emit: "void libwirefastNimMain(void) {}".}

declareLibrary("wirefast", WireLib, defaultABIFormat = "c")

type WireConfig {.ffi.} = object
  tag: string

type BulkRequest {.ffi.} = object
  items: seq[string]
  note: Option[string]

type BulkResponse {.ffi.} = object
  joined: string
  count: int
  echoed: seq[string]

proc wirefast_create*(cfg: WireConfig): Future[Result[WireLib, string]] {.ffiCtor.} =
  return ok(WireLib(tag: cfg.tag))

proc wirefast_bulk*(
    lib: WireLib, req: BulkRequest
): Future[Result[BulkResponse, string]] {.ffi.} =
  let note = req.note.get("none")
  return ok(
    BulkResponse(
      joined: lib.tag & ":" & req.items.join(",") & "/" & note,
      count: req.items.len,
      echoed: req.items,
    )
  )

proc wirefast_greet*(
    lib: WireLib, req: BulkRequest
): Future[Result[string, string]] {.ffi.} =
  ## String return: rides back as raw UTF-8, not CBOR.
  if req.items.len == 0:
    return err("no items")
  return ok(lib.tag & " greets " & req.items[0])

genBindings()

type ReplyData = object
  ## One latch per call; `text` doubles as the ctor's address string.
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  text: string
  errMsg: string
  count: int
  echoed: seq[string]

proc initReplyData(d: var ReplyData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitReplyData(d: var ReplyData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

proc waitReply(d: var ReplyData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc signalReply(d: ptr ReplyData, err: cint, errMsg: cstring) =
  d[].retCode = err
  if err != RET_OK and not errMsg.isNil():
    d[].errMsg = $errMsg
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc onStringReply(
    err: cint, reply: cstring, errMsg: cstring, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Shared by the ctor's address string and `greet`'s raw-UTF-8 return.
  let d = cast[ptr ReplyData](ud)
  acquire(d[].lock)
  if err == RET_OK and not reply.isNil():
    d[].text = $reply
  signalReply(d, err, errMsg)

proc onBulkReply(
    err: cint, reply: ptr BulkResponse_CWire, errMsg: cstring, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Reads the reply wire struct before the trampoline frees it.
  let d = cast[ptr ReplyData](ud)
  acquire(d[].lock)
  if err == RET_OK and not reply.isNil():
    d[].text = $reply[].joined
    d[].count = reply[].count
    d[].echoed = @[]
    for i in 0 ..< reply[].echoed_len:
      d[].echoed.add($reply[].echoed_items[i])
  signalReply(d, err, errMsg)

proc packedWire[W, R](_: typedesc[W], envelope: R): W =
  ## The caller-owned request struct a foreign caller would hand the wrapper.
  var wire: W
  cwirePack(wire, envelope)
  wire

proc bulkReq(items: seq[string], note: Option[string]): BulkRequest =
  BulkRequest(items: items, note: note)

proc makeCtx(tag: string): ptr FFIContext[WireLib] =
  var d: ReplyData
  initReplyData(d)
  defer:
    deinitReplyData(d)

  var wire = packedWire(
    WirefastCreateCtorReq_CWire, WirefastCreateCtorReq(cfg: WireConfig(tag: tag))
  )
  defer:
    cwireFree(wire)

  doAssert not WirefastCreateCtorReqCAbiExport(addr wire, onStringReply, addr d).isNil()
  waitReply(d)
  doAssert d.retCode == RET_OK
  cast[ptr FFIContext[WireLib]](cast[uint](parseBiggestUInt(d.text)))

suite "abi = c non-scalar dispatch — CBOR-free wire transport":
  test "seq + Option request round-trips into an object reply":
    let ctx = makeCtx("bulk")
    defer:
      check WireLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: ReplyData
    initReplyData(d)
    defer:
      deinitReplyData(d)

    var req = packedWire(
      WirefastBulkReq_CWire, WirefastBulkReq(req: bulkReq(@["a", "b", "c"], some("hi")))
    )
    defer:
      cwireFree(req)

    check WirefastBulkReqCAbiExport(ctx, onBulkReply, addr d, addr req) == RET_OK
    waitReply(d)

    check d.retCode == RET_OK
    check d.text == "bulk:a,b,c/hi"
    check d.count == 3
    check d.echoed == @["a", "b", "c"]

  test "none Option and empty seq survive the hop":
    let ctx = makeCtx("empty")
    defer:
      check WireLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: ReplyData
    initReplyData(d)
    defer:
      deinitReplyData(d)

    var req = packedWire(
      WirefastBulkReq_CWire, WirefastBulkReq(req: bulkReq(@[], none(string)))
    )
    defer:
      cwireFree(req)

    check WirefastBulkReqCAbiExport(ctx, onBulkReply, addr d, addr req) == RET_OK
    waitReply(d)

    check d.retCode == RET_OK
    check d.text == "empty:/none"
    check d.count == 0
    check d.echoed.len == 0

  test "string return rides back as raw UTF-8":
    let ctx = makeCtx("greeter")
    defer:
      check WireLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: ReplyData
    initReplyData(d)
    defer:
      deinitReplyData(d)

    var req = packedWire(
      WirefastGreetReq_CWire, WirefastGreetReq(req: bulkReq(@["world"], none(string)))
    )
    defer:
      cwireFree(req)

    check WirefastGreetReqCAbiExport(ctx, onStringReply, addr d, addr req) == RET_OK
    waitReply(d)

    check d.retCode == RET_OK
    check d.text == "greeter greets world"

  test "handler error surfaces as RET_ERR with the message":
    let ctx = makeCtx("greeter")
    defer:
      check WireLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: ReplyData
    initReplyData(d)
    defer:
      deinitReplyData(d)

    var req = packedWire(
      WirefastGreetReq_CWire, WirefastGreetReq(req: bulkReq(@[], none(string)))
    )
    defer:
      cwireFree(req)

    check WirefastGreetReqCAbiExport(ctx, onStringReply, addr d, addr req) == RET_OK
    waitReply(d)

    check d.retCode == RET_ERR
    check d.errMsg == "no items"
