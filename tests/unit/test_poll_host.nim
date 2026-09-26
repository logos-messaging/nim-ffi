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

# The exports are this image's own; the host binds them by C name all the same.
let library = importLibrary("pollhost", ctor = "pollhost_create")

var greeted: Atomic[int]
var sinkHost: Host
var answered: Thread[(pointer, uint64)]
var lastAnswered: Atomic[uint64]

suite "a Nim host of a poll-mode library":
  test "the constructor's reply is what create answers":
    let host = newHost(library)
    check host.create(request({"who": ""}), 5_000).error == "nobody to greet"
    check host.ctx.isNil
    check host.create(request({"who": "world"}), 5_000).isOk
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
    check host.create(request({"who": "x"}), 5_000).isOk
    let r = host.call("pollhost_greet", request({"who": "world"}), 5_000)
    check r.ret == RET_OK
    check r.decode(string).get() == "hello world"
    check greeted.load() == 1
    host.destroy()

  test "an error reply carries the library's text":
    let host = newHost(library)
    check host.create(request({"who": "x"}), 5_000).isOk
    let r = host.call("pollhost_refuse", request({}))
    check r.ret == RET_ERR
    check r.error == "no"
    check r.decode(string).error == "no"
    check r.outcome.error == "no"
    host.destroy()

  test "a reverse call is served from inside the wait":
    var host: Host
    host = newHost(
      library,
      onReverseCall = proc(callId, nameId: uint64, args: seq[byte]) {.gcsafe, raises: [].} =
        lastAnswered.store(callId)
        discard host.reverseReply(callId, RET_OK, cborEncode("an answer")),
    )
    check host.create(request({"who": "x"}), 5_000).isOk
    let r = host.call("pollhost_ask", request({}), 5_000)
    check r.ret == RET_OK
    check r.decode(string).get() == "an answer"
    check lastAnswered.load() != 0'u64
    host.destroy()

  test "a question handed to an in-image sink is answered through reverse_reply":
    proc answer(call: (pointer, uint64)) {.thread.} =
      let bytes = cborEncode("from the sink")
      {.cast(gcsafe).}:
        discard pollhost_reverse_reply(
          cast[FFICtxToken](call[0]), call[1], RET_OK, unsafeAddr bytes[0], csize_t(bytes.len)
        )
    setFFIReverseSink(
      proc(callId, nameId: uint64, args: pointer, len: int) {.nimcall, gcsafe, raises: [].} =
        {.cast(gcsafe), cast(raises: []).}:
          createThread(answered, answer, (sinkHost.ctx, callId))
    )
    sinkHost = newHost(library)
    check sinkHost.create(request({"who": "x"})).isOk
    let r = sinkHost.call("pollhost_ask", request({}))
    check r.decode(string).get() == "from the sink"
    joinThread(answered)
    setFFIReverseSink(nil)
    sinkHost.destroy()

  test "a submitted call's reply is dropped, later calls still match theirs":
    let host = newHost(library)
    check host.create(request({"who": "x"}), 5_000).isOk
    check host.submit("pollhost_greet", request({"who": "a"})).isOk
    let r = host.call("pollhost_greet", request({"who": "b"}), 5_000)
    check r.decode(string).get() == "hello b"
    host.drain()
    host.destroy()
