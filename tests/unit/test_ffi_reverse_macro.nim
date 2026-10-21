## The `{.ffiReverse.}` and `{.ffiReverseEvent.}` exports of a declared library, end to end.

import std/[locks, os, strutils]
import unittest2
import results
import ffi
import ffi/codegen/meta

type RevMacroLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void librevmacroNimMain(void) {}".}

declareLibrary("revmacro", RevMacroLib)

type RevConfig* {.ffi.} = object
  name*: string
  attempt*: int

proc fetchConfig(
    key: string, attempt: int
): Future[Result[RevConfig, string]] {.ffiReverse.} =
  ## Asks the host for a config entry.

proc notifyHost(
  note: string
): Future[Result[void, string]] {.ffiReverse("host_note", timeout = 300).}

proc pingHost(): Future[Result[void, string]] {.ffiReverse.}

static:
  doAssert ffiReverseRegistry.len == 3
  doAssert ffiReverseRegistry[0].wireName == "fetch_config"
  doAssert ffiReverseRegistry[0].argsTypeName == "FetchConfigArgs"
  doAssert ffiReverseRegistry[0].replyTypeName == "RevConfig"
  # A comment-only body is how a bodyless proc keeps its doc: Nim drops a
  # `##` that follows a declaration without `=`.
  doAssert ffiReverseRegistry[0].doc == "Asks the host for a config entry."
  doAssert ffiReverseRegistry[1].wireName == "host_note"
  doAssert ffiReverseRegistry[1].replyTypeName == ""
  doAssert ffiReverseRegistry[1].timeoutMs == 300
  doAssert ffiReverseRegistry[2].wireName == "ping_host"
  doAssert ffiReverseRegistry[2].argsTypeName == ""

registerReqFFI(DriveFetchRequest, h: ptr FFIContext[RevMacroLib]):
  proc(): Future[Result[string, string]] {.async.} =
    let cfg = (await fetchConfig("theme", 2)).valueOr:
      return err(error)
    if cfg.name != "theme!" or cfg.attempt != 3:
      return err("unexpected reply: " & cfg.name & "/" & $cfg.attempt)
    return ok("fetched")

registerReqFFI(DriveNotifyRequest, h: ptr FFIContext[RevMacroLib]):
  proc(): Future[Result[string, string]] {.async.} =
    (await notifyHost("hello")).isOkOr:
      return err(error)
    return ok("notified")

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

template setupCallbackData(name: untyped) =
  var name: CallbackData
  initCallbackData(name)
  defer:
    deinitCallbackData(name)

proc captureCb(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  if retCode != RET_STALE_WARN:
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

proc callbackMsg(d: var CallbackData): string =
  var msg = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr msg[0], addr d.msg[0], d.msgLen)
  return msg

template withLibCtx(ctxIdent, tokenIdent: untyped, body: untyped) =
  ## The declareLibrary pool, so that the generated exports resolve the context.
  let ctxIdent = RevMacroLibFFIPool.createFFIContext().valueOr:
    check false
    return
  let tokenIdent = ctxIdent.ffiToken()
  defer:
    discard RevMacroLibFFIPool.destroyFFIContext(ctxIdent)
  body

type TokenBox = object
  token: FFICtxToken

proc fetchConfigImpl(
    ctx: pointer,
    callId: uint64,
    args: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  # Nim code that touches the pool global is not gcsafe; a C host has no such check.
  {.cast(gcsafe).}:
    let box = cast[ptr TokenBox](userData)
    let decoded = cborDecodePtr(args, int(argsLen), FetchConfigArgs).valueOr:
      let msg = "args decode failed"
      discard revmacro_reverse_reply(
        box[].token,
        callId,
        RET_ERR,
        cast[ptr byte](unsafeAddr msg[0]),
        csize_t(msg.len),
      )
      return
    let reply =
      cborEncode(RevConfig(name: decoded.key & "!", attempt: decoded.attempt + 1))
    discard revmacro_reverse_reply(
      box[].token,
      callId,
      RET_OK,
      cast[ptr byte](unsafeAddr reply[0]),
      csize_t(reply.len),
    )

proc ackNoteImpl(
    ctx: pointer,
    callId: uint64,
    args: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  # Replies with the token it is handed, not one the host kept.
  {.cast(gcsafe).}:
    discard revmacro_reverse_reply(FFICtxToken(ctx), callId, RET_OK, nil, 0)

var gPingArgs: array[2, Atomic[int]] # argsLen, first byte

proc pingImpl(
    ctx: pointer,
    callId: uint64,
    args: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    gPingArgs[0].store(int(argsLen))
    gPingArgs[1].store(
      if argsLen > 0:
        int(args[0])
      else:
        -1
    )
    discard revmacro_reverse_reply(FFICtxToken(ctx), callId, RET_OK, nil, 0)

proc countRelease(userData: pointer) {.cdecl, gcsafe, raises: [].} =
  cast[ptr Atomic[int]](userData)[].atomicInc()

proc silentImpl(
    ctx: pointer,
    callId: uint64,
    args: ptr UncheckedArray[byte],
    argsLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  discard

registerReqFFI(DrivePingRequest, h: ptr FFIContext[RevMacroLib]):
  proc(): Future[Result[string, string]] {.async.} =
    (await pingHost()).isOkOr:
      return err(error)
    return ok("pinged")

suite "{.ffiReverse.} through the generated exports":
  test "multi-param call: synthesized args object and typed reply roundtrip":
    setupCallbackData(rsp)
    withLibCtx(ctx, token):
      var box = TokenBox(token: token)
      check revmacro_set_fetch_config_impl(token, fetchConfigImpl, addr box, nil) ==
        REVERSE_ACCEPTED

      check sendRequestToFFIThread(
        ctx, DriveFetchRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_OK
      check "fetched" in callbackMsg(rsp)

  test "void-reply call under a custom wire name":
    setupCallbackData(rsp)
    withLibCtx(ctx, token):
      check revmacro_set_host_note_impl(token, ackNoteImpl, nil, nil) == REVERSE_ACCEPTED

      check sendRequestToFFIThread(
        ctx, DriveNotifyRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_OK
      check "notified" in callbackMsg(rsp)

  test "a parameterless call sends an empty CBOR map":
    setupCallbackData(rsp)
    withLibCtx(ctx, token):
      check revmacro_set_ping_host_impl(token, pingImpl, nil, nil) == REVERSE_ACCEPTED
      check sendRequestToFFIThread(ctx, DrivePingRequest.ffiNewReq(captureCb, addr rsp))
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_OK
      check gPingArgs[0].load() == 1
      check gPingArgs[1].load() == 0xa0

  test "pragma-level timeout override fires":
    setupCallbackData(rsp)
    withLibCtx(ctx, token):
      check revmacro_set_host_note_impl(token, silentImpl, nil, nil) == REVERSE_ACCEPTED
      check sendRequestToFFIThread(
        ctx, DriveNotifyRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_ERR
      check "timed out after 300 ms" in callbackMsg(rsp)

  test "unfulfilled interface fails fast; stale token is rejected":
    setupCallbackData(rsp)
    withLibCtx(ctx, token):
      check sendRequestToFFIThread(
        ctx, DriveFetchRequest.ffiNewReq(captureCb, addr rsp)
      )
        .isOk()
      waitCallback(rsp)
      check rsp.retCode == RET_ERR
      check "no host implementation" in callbackMsg(rsp)

      check revmacro_set_fetch_config_impl(FFICtxToken(nil), fetchConfigImpl, nil, nil) ==
        REVERSE_INVALID_CTX
      check revmacro_reverse_reply(FFICtxToken(nil), 1'u64, RET_OK, nil, 0) ==
        REVERSE_INVALID_CTX

suite "reverse_reply boundaries":
  test "a reply over MaxRequestPayloadBytes is rejected before it is read":
    withLibCtx(ctx, token):
      var b = [byte 0]
      # Only the length is checked; the one-byte buffer is never read.
      check revmacro_reverse_reply(
        token, 1'u64, RET_OK, addr b[0], csize_t(MaxRequestPayloadBytes + 1)
      ) == REVERSE_PAYLOAD_TOO_LARGE
      check ctx[].reverse.mailboxLen() == 0

  test "a length past high(int) is rejected, cap or not":
    withLibCtx(ctx, token):
      var b = [byte 0]
      check revmacro_reverse_reply(
        token, 1'u64, RET_OK, addr b[0], csize_t(high(int)) + 1
      ) == REVERSE_PAYLOAD_TOO_LARGE
      check ctx[].reverse.mailboxLen() == 0

  test "a NULL reply with a length is an invalid argument, not an empty reply":
    withLibCtx(ctx, token):
      check revmacro_reverse_reply(token, 1'u64, RET_OK, nil, 16) ==
        REVERSE_INVALID_ARGUMENT
      check ctx[].reverse.mailboxLen() == 0

  test "the previous owner's token no longer reaches a reused slot":
    let first = RevMacroLibFFIPool.createFFIContext().valueOr:
      check false
      return
    let oldToken = first.ffiToken()
    check RevMacroLibFFIPool.destroyFFIContext(first).isOk()
    withLibCtx(ctx, token):
      check ctx == first # same slot, new owner
      check revmacro_reverse_reply(oldToken, 1'u64, RET_OK, nil, 0) ==
        REVERSE_INVALID_CTX
      check revmacro_set_host_note_impl(oldToken, silentImpl, nil, nil) ==
        REVERSE_INVALID_CTX
      check not ctx[].reverse.isRegistered("host_note")
      check ctx[].reverse.mailboxLen() == 0

suite "reverse worker start":
  test "set_impl starts the workers lazily; a fresh context has none":
    withLibCtx(ctx, token):
      check not ctx[].reverse.workersStarted()
      check revmacro_set_host_note_impl(token, silentImpl, nil, nil) == REVERSE_ACCEPTED
      check ctx[].reverse.workersStarted()
      check ctx[].reverse.workerCount == ReverseWorkersDefault

suite "set_impl ownership through the export":
  test "with a release the library frees userData once the impl is replaced":
    withLibCtx(ctx, token):
      var a, b: Atomic[int]
      check revmacro_set_host_note_impl(token, silentImpl, addr a, countRelease) ==
        REVERSE_ACCEPTED
      check revmacro_set_host_note_impl(token, silentImpl, addr b, countRelease) ==
        REVERSE_ACCEPTED
      check a.load() == 1 # idle, so released at once
      check b.load() == 0
      check revmacro_set_host_note_impl(token, nil, nil, nil) == REVERSE_ACCEPTED
      check b.load() == 1

  test "a refused registration never calls the release":
    var a: Atomic[int]
    check revmacro_set_host_note_impl(
      FFICtxToken(nil), silentImpl, addr a, countRelease
    ) == REVERSE_INVALID_CTX
    check a.load() == 0
