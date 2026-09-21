## A hostile host, through the real C exports: several threads submit while one
## polls, and the context is destroyed under them. Every accepted request is
## answered exactly once or cut off by the close; nothing is answered twice,
## nothing hangs, and a token that outlived its context is refused.
## Validate with NIM_FFI_SAN=tsan NIM_FFI_MM=orc.

import std/[atomics, os]
import unittest2
import results
import ffi
import ./helpers

type SoakLib = ref object
  served: int

type SoakTick {.ffi.} = object
  n: int

{.emit: "void libsoakNimMain(void) {}".}

declareLibrary("soak", SoakLib)

proc soak_create*(): Future[Result[SoakLib, string]] {.ffiCtor.} =
  return ok(SoakLib())

proc onSoakTick*(evt: SoakTick) {.ffiEvent.}

proc soak_work*(lib: SoakLib, n: int): Future[Result[int, string]] {.ffi.} =
  # Some requests yield, so replies complete out of submit order.
  if n mod 7 == 0:
    await sleepAsync(1.milliseconds)
  lib.served.inc()
  onSoakTick(SoakTick(n: n))
  return ok(n)

proc soak_destroy*(lib: SoakLib) {.ffiDtor.} =
  discard

startWatchdog(180_000, "the soak test hung: a poll or a destroy never returned")

const
  Submitters = 4
  MaxIds = 1 shl 22

type Shared = object
  token: FFICtxToken
  stop: Atomic[bool]
  accepted: Atomic[int]
  refused: Atomic[int]
  replies: Atomic[int]
  events: Atomic[int]
  pollerRet: Atomic[int]
  answered: array[MaxIds, Atomic[int]] # by request id: how many replies it got

proc submitLoop(sh: ptr Shared) =
  var n = 0
  while not sh.stop.load():
    var req = cborEncode(SoakWorkReq(n: n))
    var reqId = 0'u64
    let rc = soak_work(sh.token, encodedPtr(req), req.len.csize_t, addr reqId)
    if rc == RET_OK:
      doAssert reqId != 0
      sh.accepted.atomicInc()
    else:
      doAssert reqId == 0, "a refused request kept an id"
      doAssert $soak_last_error() != "", "a refusal without a reason"
      sh.refused.atomicInc()
      if rc == RET_QUEUE_FULL:
        os.sleep(1)
    n.inc()

# The exports are plain C entry points; a host thread calls them without the GC-safety proof.
proc submitterBody(sh: ptr Shared) {.thread.} =
  {.cast(gcsafe).}:
    submitLoop(sh)

proc pollLoop(sh: ptr Shared) =
  var polled = 0
  while true:
    var msg: ptr NimFfiMsg
    let rc = soak_poll(sh.token, 100, addr msg)
    if rc == RET_OK:
      polled.inc()
      # A slow host: it reads the message a while after the poll returned, while
      # the producers keep going and a destroy may be tearing the context down.
      if polled mod 64 == 0:
        os.sleep(1)
      var payload = newSeq[byte](int(msg.len))
      if msg.len > 0:
        copyMem(addr payload[0], msg.payload, int(msg.len))
      if msg.kind == MsgReply:
        doAssert msg.id < MaxIds
        sh.answered[int(msg.id)].atomicInc()
        sh.replies.atomicInc()
        # The ctor's reply carries no value; every other one is the `n` it was sent.
        if msg.retCode == RET_OK and payload != @[CborNullByte]:
          doAssert cborDecode(payload, int).isOk(), "a reply payload was corrupted"
      elif msg.kind == MsgEvent:
        doAssert msg.nameId == nameId("on_soak_tick")
        doAssert cborDecode(payload, SoakTick).isOk(), "an event payload was corrupted"
        sh.events.atomicInc()
    elif rc == RET_TIMEOUT:
      discard
    else:
      sh.pollerRet.store(int(rc))
      return

proc pollerBody(sh: ptr Shared) {.thread.} =
  {.cast(gcsafe).}:
    pollLoop(sh)

proc runRound(sh: ptr Shared, runMs: int) =
  var reqId: uint64
  var cfg = cborEncode(SoakCreateCtorReq())
  doAssert soak_create(encodedPtr(cfg), cfg.len.csize_t, addr sh.token, addr reqId) ==
    RET_OK
  sh.stop.store(false)
  sh.pollerRet.store(-1)

  var poller: Thread[ptr Shared]
  var submitters: array[Submitters, Thread[ptr Shared]]
  createThread(poller, pollerBody, sh)
  for i in 0 ..< Submitters:
    createThread(submitters[i], submitterBody, sh)

  os.sleep(runMs)
  # Destroy with everyone still running: submitters mid-call, the poller blocked.
  doAssert soak_destroy(sh.token) == RET_OK
  sh.stop.store(true)
  for i in 0 ..< Submitters:
    joinThread(submitters[i])
  joinThread(poller)

suite "soak through the C exports":
  test "submit, poll and destroy race for many rounds":
    var sh = cast[ptr Shared](allocShared0(sizeof(Shared)))
    defer:
      deallocShared(sh)

    for round in 0 ..< 12:
      runRound(sh, 60)
      # The poller left because its context ended, not because of an error.
      check sh.pollerRet.load() in [int(RET_CLOSED), int(RET_INVALID_CTX)]

      # The token died with its context.
      var req = cborEncode(SoakWorkReq(n: 1))
      var reqId = 0'u64
      check soak_work(sh.token, encodedPtr(req), req.len.csize_t, addr reqId) ==
        RET_INVALID_CTX
      check soak_destroy(sh.token) == RET_INVALID_CTX
      var msg: ptr NimFfiMsg
      check soak_poll(sh.token, 0, addr msg) == RET_INVALID_CTX

    # No request was answered twice. The ctor's reply of each round is counted too.
    var doubles = 0
    for i in 0 ..< MaxIds:
      if sh.answered[i].load() > 1:
        doubles.inc()
    check doubles == 0
    check sh.replies.load() > 0
    check sh.events.load() > 0
    # Requests cut off by a destroy are never answered; everything else is.
    check sh.replies.load() <= sh.accepted.load() + 12
    echo "soak: accepted=",
      sh.accepted.load(),
      " refused=",
      sh.refused.load(),
      " replies=",
      sh.replies.load(),
      " events=",
      sh.events.load()

  test "a context destroyed before its ctor ran gives its slot back":
    # More rounds than the pool has slots: a leak would exhaust it.
    for _ in 0 ..< MaxFFIContexts + 8:
      var token: FFICtxToken
      var reqId: uint64
      var cfg = cborEncode(SoakCreateCtorReq())
      check soak_create(encodedPtr(cfg), cfg.len.csize_t, addr token, addr reqId) ==
        RET_OK
      check soak_destroy(token) == RET_OK
