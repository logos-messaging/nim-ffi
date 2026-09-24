## Calls the other way: a handler asks the host for something and waits. The
## question comes out of `poll` like any other message, and the answer goes back
## through `<lib>_reverse_reply`. Built with `-d:ffiPollMode` (see the .cfg).

import std/[os, strutils]
import unittest2
import results
import ffi
import ./helpers

type ReverseLib = ref object

type HostFetchHostCallArgs = object ## What the test decodes on the host side.
  url*: string

{.emit: "void librevNimMain(void) {}".}

declareLibrary("rev", ReverseLib)

proc rev_create*(): Future[Result[ReverseLib, string]] {.ffiCtor.} =
  return ok(ReverseLib())

proc hostFetch*(url: string): Future[Result[string, string]] {.ffiReverse.}

proc rev_fetch*(lib: ReverseLib, url: string): Future[Result[string, string]] {.ffi.} =
  # What a handler does with it: ask the host, then answer its own caller.
  let body = (await hostFetch(url)).valueOr:
    return err("host said: " & error)
  return ok("got " & body)

proc rev_destroy*(lib: ReverseLib) {.ffiDtor.} =
  discard

startWatchdog(120_000, "a reverse call never came back")

proc createCtx(token: var FFICtxToken) =
  var reqId: uint64
  var cfg = cborEncode(RevCreateCtorReq())
  doAssert rev_create(encodedPtr(cfg), cfg.len.csize_t, addr token, addr reqId) == RET_OK

proc pollFor(
    token: FFICtxToken, kind: uint32, timeoutMs = 5000
): tuple[msg: NimFfiMsg, payload: seq[byte]] =
  ## Drains until a message of `kind` arrives; the test is the host's loop.
  let deadline = Moment.now() + timeoutMs.milliseconds
  while Moment.now() < deadline:
    var msg: ptr NimFfiMsg
    let rc = rev_poll(token, 200, addr msg)
    if rc != RET_OK:
      continue
    var payload = newSeq[byte](int(msg.len))
    if msg.len > 0:
      copyMem(addr payload[0], msg.payload, int(msg.len))
    if msg.kind == kind:
      return (msg[], payload)
  doAssert false, "no message of kind " & $kind & " arrived"

suite "a handler asks the host":
  test "the call reaches the host, and its answer reaches the handler":
    var token: FFICtxToken
    createCtx(token)
    defer:
      discard rev_destroy(token)

    var req = cborEncode(RevFetchReq(url: "https://example.test/a"))
    var reqId: uint64
    check rev_fetch(token, encodedPtr(req), req.len.csize_t, addr reqId) == RET_OK

    let (call, args) = pollFor(token, MsgReverseCall)
    check call.nameId == nameId("host_fetch")
    check call.id != 0'u64
    check call.aux > 0'u64 # milliseconds left to answer
    let decoded = cborDecode(args, HostFetchHostCallArgs)
    check decoded.isOk()
    check decoded.value.url == "https://example.test/a"

    var answer = cborEncode("hello")
    check rev_reverse_reply(
      token, call.id, RET_OK, encodedPtr(answer), answer.len.csize_t
    ) == RET_OK

    let (reply, payload) = pollFor(token, MsgReply)
    check reply.id == reqId
    check reply.retCode == RET_OK
    check cborDecode(payload, string).value == "got hello"

  test "a host that refuses is the handler's error":
    var token: FFICtxToken
    createCtx(token)
    defer:
      discard rev_destroy(token)

    var req = cborEncode(RevFetchReq(url: "https://example.test/b"))
    var reqId: uint64
    check rev_fetch(token, encodedPtr(req), req.len.csize_t, addr reqId) == RET_OK

    let (call, _) = pollFor(token, MsgReverseCall)
    var why = "no such thing"
    var whyBytes = newSeq[byte](why.len)
    copyMem(addr whyBytes[0], addr why[0], why.len)
    check rev_reverse_reply(
      token, call.id, RET_ERR, encodedPtr(whyBytes), whyBytes.len.csize_t
    ) == RET_OK

    let (reply, payload) = pollFor(token, MsgReply)
    check reply.retCode == RET_ERR
    var text = ""
    for b in payload:
      text.add(char(b))
    check text.contains("no such thing")

  test "an answer to an id nobody waits for is dropped":
    var token: FFICtxToken
    createCtx(token)
    defer:
      discard rev_destroy(token)

    var answer = cborEncode("nobody asked")
    check rev_reverse_reply(
      token, 9999'u64, RET_OK, encodedPtr(answer), answer.len.csize_t
    ) == RET_OK
    os.sleep(100) # the FFI thread drains it and finds no one to give it to

    # The context is unharmed: a real call still works.
    var req = cborEncode(RevFetchReq(url: "https://example.test/c"))
    var reqId: uint64
    check rev_fetch(token, encodedPtr(req), req.len.csize_t, addr reqId) == RET_OK
    let (call, _) = pollFor(token, MsgReverseCall)
    var ok0 = cborEncode("fine")
    check rev_reverse_reply(token, call.id, RET_OK, encodedPtr(ok0), ok0.len.csize_t) ==
      RET_OK
    let (reply, _) = pollFor(token, MsgReply)
    check reply.retCode == RET_OK

  test "a host that never answers does not park the handler for ever":
    var token: FFICtxToken
    createCtx(token)
    defer:
      discard rev_destroy(token)

    var req = cborEncode(RevFetchReq(url: "https://example.test/d"))
    var reqId: uint64
    check rev_fetch(token, encodedPtr(req), req.len.csize_t, addr reqId) == RET_OK

    let (call, _) = pollFor(token, MsgReverseCall)
    check call.id != 0'u64 # taken and never answered

    let (reply, payload) = pollFor(token, MsgReply, 10_000)
    check reply.retCode == RET_ERR
    var text = ""
    for b in payload:
      text.add(char(b))
    check text.contains("did not answer in time")

  test "a call still waiting when the context ends fails, and nothing hangs":
    var token: FFICtxToken
    createCtx(token)

    var req = cborEncode(RevFetchReq(url: "https://example.test/e"))
    var reqId: uint64
    check rev_fetch(token, encodedPtr(req), req.len.csize_t, addr reqId) == RET_OK
    discard pollFor(token, MsgReverseCall)

    check rev_destroy(token) == RET_OK
    var msg: ptr NimFfiMsg
    check rev_poll(token, 0, addr msg) == RET_INVALID_CTX
