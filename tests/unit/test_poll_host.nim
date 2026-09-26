## `ffi/poll_host`: a Nim host driving a poll-mode library in the same image
## through its C exports -- the shape a library takes when it ships inside a
## larger Nim program. Built with `-d:ffiPollMode` (see the .cfg beside this).

import std/[atomics, os]
import unittest2
import results
import ffi
import ffi/poll_host

type HostedLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libpollhostNimMain(void) {}".}

declareLibrary("pollhost", HostedLib)

type Greeting {.ffi.} = object
  who: string

proc pollhost_create(who: string): Future[Result[HostedLib, string]] {.ffiCtor.} =
  if who.len == 0:
    return err("nobody to greet")
  return ok(HostedLib())

proc pollhost_greet(lib: HostedLib, who: string): Future[Result[string, string]] {.ffi.} =
  dispatchFFIEventCbor("greeted", Greeting(who: who))
  return ok("hello " & who)

proc pollhost_refuse(lib: HostedLib): Future[Result[string, string]] {.ffi.} =
  return err("no")

proc askHost(question: string): Future[Result[string, string]] {.ffiReverse.}

proc pollhost_ask(lib: HostedLib): Future[Result[string, string]] {.ffi.} =
  let answer = await askHost("a question")
  return answer

proc pollhost_destroy(lib: HostedLib) {.ffiDtor.} =
  discard

type
  CreateReq = object
    who: string
  GreetReq = object
    who: string
  Empty = object

# The C exports share their names with the Nim procs they wrap; the expected
# type picks the export. Only the token's spelling differs from poll_host's.
type
  CtorExport = proc(
    reqCbor: ptr byte, reqCborLen: csize_t, ctxOut: ptr FFICtxToken, reqIdOut: ptr uint64
  ): cint {.cdecl, raises: [].}
  MethodExport = proc(
    ctx: FFICtxToken, reqCbor: ptr byte, reqCborLen: csize_t, reqIdOut: ptr uint64
  ): cint {.cdecl, raises: [].}
  DestroyExport = proc(ctx: FFICtxToken): cint {.cdecl, raises: [].}

template asMethod(p: untyped): MethodFn =
  block:
    let e: MethodExport = p
    cast[MethodFn](e)

let createExport: CtorExport = pollhost_create
let destroyExport: DestroyExport = pollhost_destroy
let library = Library(
  create: cast[CtorFn](createExport),
  destroy: cast[DestroyFn](destroyExport),
  poll: cast[PollFn](pollhost_poll),
  reverseReply: cast[ReverseReplyFn](pollhost_reverse_reply),
)

var greeted: Atomic[int]
var lastAnswered: Atomic[uint64]

suite "a Nim host of a poll-mode library":
  test "the constructor's reply is what create answers":
    let host = newHost(library)
    check host.create(encode(CreateReq(who: "")), 5_000).error == "nobody to greet"
    check host.ctx.isNil
    check host.create(encode(CreateReq(who: "world")), 5_000).isOk
    check not host.ctx.isNil
    host.destroy()

  test "a call pumps until its reply, dispatching the events on the way":
    greeted.store(0)
    let host = newHost(
      library,
      onEvent = proc(nameId: uint64, payload: seq[byte]) {.gcsafe, raises: [].} =
        if nameId == nameId("greeted"):
          let g = cborDecode(payload, Greeting)
          if g.isOk and g.value.who == "world":
            discard greeted.fetchAdd(1),
    )
    check host.create(encode(CreateReq(who: "x")), 5_000).isOk
    let r = host.call(asMethod(pollhost_greet), encode(GreetReq(who: "world")), 5_000)
    check r.ret == RET_OK
    check r.decode(string).get() == "hello world"
    check greeted.load() == 1
    host.destroy()

  test "an error reply carries the library's text":
    let host = newHost(library)
    check host.create(encode(CreateReq(who: "x")), 5_000).isOk
    let r = host.call(asMethod(pollhost_refuse), encode(Empty()), 5_000)
    check r.ret == RET_ERR
    check r.error == "no"
    check r.decode(string).error == "no"
    host.destroy()

  test "a reverse call is served from inside the wait":
    var host: Host
    host = newHost(
      library,
      onReverseCall = proc(callId, nameId: uint64, args: seq[byte]) {.gcsafe, raises: [].} =
        lastAnswered.store(callId)
        discard host.reverseReply(callId, RET_OK, cborEncode("an answer")),
    )
    check host.create(encode(CreateReq(who: "x")), 5_000).isOk
    let r = host.call(asMethod(pollhost_ask), encode(Empty()), 5_000)
    check r.ret == RET_OK
    check r.decode(string).get() == "an answer"
    check lastAnswered.load() != 0'u64
    host.destroy()

  test "a submitted call's reply is dropped, later calls still match theirs":
    let host = newHost(library)
    check host.create(encode(CreateReq(who: "x")), 5_000).isOk
    check host.submit(asMethod(pollhost_greet), encode(GreetReq(who: "a"))).isOk
    let r = host.call(asMethod(pollhost_greet), encode(GreetReq(who: "b")), 5_000)
    check r.decode(string).get() == "hello b"
    host.drain()
    host.destroy()
