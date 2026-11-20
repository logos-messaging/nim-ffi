## `ffi/poll_host`: a Nim host driving a poll-mode library in the same image
## through its C exports -- the shape a library takes when it ships inside a
## larger Nim program. Built with `-d:ffiPollMode` (see the .cfg beside this).

import std/[atomics, monotimes, os, strutils, times]
import unittest2
import results
import ffi
import ffi/poll_host
import ffi/ffi_msg

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

proc pollhost_greet(
    lib: HostedLib, who: string
): Future[Result[string, string]] {.ffi.} =
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
var lastAnswered: Atomic[uint64]

suite "a Nim host of a poll-mode library":
  test "the constructor's reply is what create answers":
    let host = newHost(library)
    check host.create(request({"who": ""}), 5_000).error ==
      "constructor failed: nobody to greet"
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
            discard greeted.fetchAdd(1)
      ,
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
    check r.decode(string).error == "reply is not a value: no"
    check r.outcome.error == "call failed: no"
    host.destroy()

  test "a reverse call is served from inside the wait":
    var host: Host
    host = newHost(
      library,
      onReverseCall = proc(
          callId, nameId: uint64, args: seq[byte]
      ) {.gcsafe, raises: [].} =
        lastAnswered.store(callId)
        discard host.reverseReply(callId, RET_OK, cborEncode("an answer")),
    )
    check host.create(request({"who": "x"}), 5_000).isOk
    let r = host.call("pollhost_ask", request({}), 5_000)
    check r.ret == RET_OK
    check r.decode(string).get() == "an answer"
    check lastAnswered.load() != 0'u64
    host.destroy()

  test "a submitted call's reply is dropped, later calls still match theirs":
    let host = newHost(library)
    check host.create(request({"who": "x"}), 5_000).isOk
    check host.submit("pollhost_greet", request({"who": "a"})).isOk
    let r = host.call("pollhost_greet", request({"who": "b"}), 5_000)
    check r.decode(string).get() == "hello b"
    host.drain()
    host.destroy()

  test "a call times out by the clock even while events keep arriving":
    let host = newHost(
      library,
      onEvent = proc(nameId: uint64, payload: seq[byte]) {.gcsafe, raises: [].} =
        discard,
    )
    check host.create(request({"who": "x"}), 5_000).isOk
    # Each greet emits an event, so every poll of the wait returns a message.
    for i in 0 ..< 200:
      check host.submit("pollhost_greet", request({"who": "flood"})).isOk
    let started = getMonoTime()
    let r = host.call("pollhost_ask", request({}), 100)
    check (getMonoTime() - started).inMilliseconds < 5_000
    host.destroy()

  test "the late reply of a timed-out call is dropped, not kept":
    let host = newHost(library)
    check host.create(request({"who": "x"}), 5_000).isOk
    let r = host.call("pollhost_greet", request({"who": "a"}), 0)
    check r.ret == RET_TIMEOUT
    sleep(100)
    host.drain()
    check host.pollFd() >= 0
    host.destroy()

suite "host/nim_ffi.h":
  test "declares every message kind the library sends":
    const header = staticRead("../../host/nim_ffi.h")
    for k in MsgKinds:
      check ("#define NIMFFI_MSG_" & k.name & " " & $k.value & " ") in header
