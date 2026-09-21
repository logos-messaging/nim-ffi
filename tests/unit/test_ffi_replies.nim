## Replies reach the host through `poll`: one per accepted request, never lost to
## an event burst, matched by an id that is never reused, and announced by at most
## one pending stale warning. A refused call leaves its reason in the last error.

import std/[atomics, locks, os, sequtils, strutils]
import unittest2
import results
import ffi
import ./helpers

type RepliesLib = object
  tag: int

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void librepliestestNimMain(void) {}".}

declareLibrary("repliestest", RepliesLib)

type Tick {.ffi.} = object
  iter: int

proc repliestest_create*(tag: int): Future[Result[RepliesLib, string]] {.ffiCtor.} =
  return ok(RepliesLib(tag: tag))

proc repliestest_destroy*(lib: RepliesLib) {.ffiDtor.} =
  discard

proc onTick*(evt: Tick) {.ffiEvent: "on_tick".}

proc repliestest_ping*(lib: RepliesLib, n: int): Future[Result[int, string]] {.ffi.} =
  return ok(n)

proc repliestest_burst*(
    lib: RepliesLib, count: int
): Future[Result[int, string]] {.ffi.} =
  ## Yields between chunks: a host that polls keeps up, so the event queue never overflows.
  for i in 0 ..< count:
    onTick(Tick(iter: i))
    if i mod 100 == 99:
      await sleepAsync(1.milliseconds)
  return ok(count)

proc repliestest_slow*(
    lib: RepliesLib, ms: int
): Future[Result[string, string]] {.ffi.} =
  await sleepAsync(ms.milliseconds)
  return ok("slow-done")

proc repliestest_version*(): Future[Result[string, string]] {.ffiStatic.} =
  return ok("v1")

startWatchdog(120_000, "a reply never arrived")

proc createCtx(): ptr FFIContext[RepliesLib] =
  var req = cborEncode(RepliestestCreateCtorReq(tag: 1))
  var token: FFICtxToken
  var reqId: uint64
  if repliestest_create(encodedPtr(req), req.len.csize_t, addr token, addr reqId) !=
      RET_OK:
    return nil
  let ctx = RepliesLibFFIPool.resolveCtx(token)
  if ctx.isNil() or pollReply(ctx, reqId).retCode != RET_OK:
    return nil
  return ctx

proc submitPing(ctx: ptr FFIContext[RepliesLib], n: int): uint64 =
  ## 0 when the submit was refused: an id is never 0.
  var req = cborEncode(RepliestestPingReq(n: n))
  var reqId: uint64
  if repliestest_ping(ctx.ffiToken(), encodedPtr(req), req.len.csize_t, addr reqId) !=
      RET_OK:
    return 0
  return reqId

const
  PingsPerThread = 25
  Submitters = 2
  Bursts = 4
  EventsPerBurst = 500

type Submitter = object
  ctx: ptr FFIContext[RepliesLib]
  ids: array[PingsPerThread, uint64]

proc submitterBody(arg: ptr Submitter) {.thread.} =
  for i in 0 ..< PingsPerThread:
    # The export reads the pool global, as every host thread's call does.
    {.cast(gcsafe).}:
      arg.ids[i] = submitPing(arg.ctx, i)
    os.sleep(1) # spread the pings over the bursts

suite "replies and events share one stream":
  test "no reply is lost under an event burst, and each thread's replies keep their order":
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      check repliestest_destroy(ctx.ffiToken()) == RET_OK

    var burstIds: seq[uint64]
    for _ in 0 ..< Bursts:
      var req = cborEncode(RepliestestBurstReq(count: EventsPerBurst))
      var reqId: uint64
      check repliestest_burst(
        ctx.ffiToken(), encodedPtr(req), req.len.csize_t, addr reqId
      ) == RET_OK
      burstIds.add(reqId)

    var submitters: array[Submitters, Submitter]
    var threads: array[Submitters, Thread[ptr Submitter]]
    for i in 0 ..< Submitters:
      submitters[i].ctx = ctx
      createThread(threads[i], submitterBody, addr submitters[i])

    # The poller runs while the submitters and the bursts do.
    const Replies = Bursts + Submitters * PingsPerThread
    var events = 0
    var replyIds: seq[uint64]
    var lastSeq = 0'u64
    while replyIds.len < Replies or events < Bursts * EventsPerBurst:
      let got = pollMsg(ctx)
      check got.ret == RET_OK
      if got.ret != RET_OK:
        break
      check got.seq > lastSeq
      lastSeq = got.seq
      if got.kind == MsgEvent:
        events.inc()
      elif got.kind == MsgReply:
        check got.retCode == RET_OK
        replyIds.add(got.id)
      else:
        check false
    joinThreads(threads)

    check events == Bursts * EventsPerBurst
    check replyIds.len == Replies
    check not ctx.eventQueueStuck.load()
    # Exactly one reply per accepted request.
    check pollMsg(ctx, 100).ret == RET_TIMEOUT

    for id in burstIds:
      check replyIds.count(id) == 1
    for s in submitters:
      var lastAt = -1
      for i in 0 ..< PingsPerThread:
        check s.ids[i] != 0
        if i > 0:
          check s.ids[i] > s.ids[i - 1]
        check replyIds.count(s.ids[i]) == 1
        # A thread's requests are answered in the order it submitted them.
        let at = replyIds.find(s.ids[i])
        check at > lastAt
        lastAt = at

suite "stale warnings":
  test "at most one waits per request, it carries the latest figure, and the reply still comes":
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      check repliestest_destroy(ctx.ffiToken()) == RET_OK
    ctx.staleWarnInterval = 50.milliseconds

    var req = cborEncode(RepliestestSlowReq(ms: 700))
    var reqId: uint64
    check repliestest_slow(ctx.ffiToken(), encodedPtr(req), req.len.csize_t, addr reqId) ==
      RET_OK

    # Several intervals pass with nobody polling: the warnings must not pile up.
    os.sleep(320)
    var waiting = 0
    withLock ctx[].outbound.lock:
      var node = ctx[].outbound.staleHead
      while not node.isNil():
        waiting.inc()
        node = node[].staleNext
    check waiting == 1

    var warnings = 0
    var lastElapsed = 0'u64
    var reply: PolledMsg
    while true:
      let got = pollMsg(ctx)
      check got.ret == RET_OK
      if got.ret != RET_OK:
        break
      check got.id == reqId
      if got.kind == MsgReply:
        reply = got
        break
      check got.kind == MsgStaleWarn
      if warnings == 0:
        # Not the first warning's 50 ms: the one that waited was kept up to date.
        check got.aux >= 250
      check got.aux > lastElapsed
      lastElapsed = got.aux
      warnings.inc()
    check warnings >= 2
    check reply.okString() == "slow-done"
    check pollMsg(ctx, 200).ret == RET_TIMEOUT

  test "a reply supersedes the warning that still waited":
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      check repliestest_destroy(ctx.ffiToken()) == RET_OK
    ctx.staleWarnInterval = 50.milliseconds

    var req = cborEncode(RepliestestSlowReq(ms: 200))
    var reqId: uint64
    check repliestest_slow(ctx.ffiToken(), encodedPtr(req), req.len.csize_t, addr reqId) ==
      RET_OK
    check waitReplyQueued(ctx)

    let got = pollMsg(ctx)
    check got.kind == MsgReply
    check got.id == reqId
    check pollMsg(ctx, 200).ret == RET_TIMEOUT

suite "request ids":
  test "ids increase, are never 0, and a recycled slot does not reuse them":
    let first = createCtx()
    check not first.isNil()
    var lastId = 0'u64
    for i in 0 ..< 5:
      let id = submitPing(first, i)
      check id > lastId
      lastId = id
      check pollReply(first, id).retCode == RET_OK
    check repliestest_destroy(first.ffiToken()) == RET_OK
    waitSlotFree(first)

    let second = createCtx()
    check not second.isNil()
    defer:
      check repliestest_destroy(second.ffiToken()) == RET_OK
    # Lowest free slot wins, so a fresh slot here would prove nothing.
    check second == first
    # A late reader of the past owner's ids can never match a reply of this one.
    let id = submitPing(second, 0)
    check id > lastId
    check pollReply(second, id).retCode == RET_OK

  test "unpolled replies of a past owner never reach the next one":
    let first = createCtx()
    check not first.isNil()
    for i in 0 ..< 5:
      check submitPing(first, i) != 0
    check waitReplyQueued(first)
    check repliestest_destroy(first.ffiToken()) == RET_OK
    waitSlotFree(first)

    let second = createCtx()
    check not second.isNil()
    defer:
      check repliestest_destroy(second.ffiToken()) == RET_OK
    check second == first
    check nextMsg(second, 100).ret == RET_TIMEOUT
    # Nothing of the past owner counts against the outstanding cap of this one.
    check second[].outbound.outstanding.load() == 0

suite "static replies":
  test "a static call is answered on `<lib>_static_ctx()`, not on a context":
    defer:
      discard RepliesLibFFIPool.destroyStaticFFIContext()
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      check repliestest_destroy(ctx.ffiToken()) == RET_OK

    var req = cborEncode(RepliestestVersionReq())
    var firstId, secondId: uint64
    check repliestest_version(encodedPtr(req), req.len.csize_t, addr firstId) == RET_OK
    check repliestest_version(encodedPtr(req), req.len.csize_t, addr secondId) == RET_OK
    check firstId != 0
    check secondId > firstId

    let staticToken = repliestest_static_ctx()
    check not staticToken.isNil()
    check staticToken != ctx.ffiToken()
    let staticCtx = RepliesLibFFIPool.resolveCtx(staticToken)
    check not staticCtx.isNil()
    check pollReply(staticCtx, firstId).okString() == "v1"
    check pollReply(staticCtx, secondId).okString() == "v1"
    check nextMsg(ctx, 100).ret == RET_TIMEOUT

    # The host cannot destroy the static context through its token.
    check repliestest_destroy(staticToken) == RET_ERR

var gFreshThreadError: array[64, char]

proc freshThreadBody() {.thread.} =
  let text = repliestest_last_error()
  if text.isNil():
    gFreshThreadError[0] = '?'
    return
  copyMem(addr gFreshThreadError[0], text, min(text.len + 1, gFreshThreadError.len - 1))

suite "the last error of a refused call":
  test "an invalid ctx":
    var reqId = 0'u64
    check repliestest_ping(FFICtxToken(nil), nil, 0, addr reqId) == RET_INVALID_CTX
    check reqId == 0
    check $repliestest_last_error() == "ctx is not a valid FFI context"

  test "a token whose context was destroyed":
    let ctx = createCtx()
    check not ctx.isNil()
    let token = ctx.ffiToken()
    check repliestest_destroy(token) == RET_OK

    var req = cborEncode(RepliestestPingReq(n: 1))
    var reqId = 0'u64
    check repliestest_ping(token, encodedPtr(req), req.len.csize_t, addr reqId) ==
      RET_INVALID_CTX
    check reqId == 0
    check $repliestest_last_error() == "ctx is not a valid FFI context"

  test "a request stamped with the claim of a past owner":
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      check repliestest_destroy(ctx.ffiToken()) == RET_OK

    var reqId = 0'u64
    check submitRequest(
      ctx, RepliestestPingReq.ffiNewReq(1), ctx.currentGeneration() - 2, addr reqId
    ) == RET_INVALID_CTX
    check reqId == 0
    check "was recycled" in $lastError()
    check nextMsg(ctx, 100).ret == RET_TIMEOUT

  test "a payload over the cap":
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      check repliestest_destroy(ctx.ffiToken()) == RET_OK

    var big = newSeq[byte](MaxRequestPayloadBytes + 1)
    var reqId = 0'u64
    check repliestest_ping(ctx.ffiToken(), encodedPtr(big), big.len.csize_t, addr reqId) ==
      RET_TOO_LARGE
    check reqId == 0
    check "exceeds the " & $MaxRequestPayloadBytes & " byte cap" in
      $repliestest_last_error()
    check nextMsg(ctx, 100).ret == RET_TIMEOUT

  test "a NULL req_id_out":
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      check repliestest_destroy(ctx.ffiToken()) == RET_OK

    var req = cborEncode(RepliestestPingReq(n: 1))
    check repliestest_ping(ctx.ffiToken(), encodedPtr(req), req.len.csize_t, nil) ==
      RET_ERR
    check "req_id_out is NULL" in $repliestest_last_error()
    check nextMsg(ctx, 100).ret == RET_TIMEOUT

  test "the text is per thread, and empty on a thread that had no refusal":
    var reqId = 0'u64
    check repliestest_ping(FFICtxToken(nil), nil, 0, addr reqId) == RET_INVALID_CTX
    check ($repliestest_last_error()).len > 0

    gFreshThreadError[0] = '!'
    var th: Thread[void]
    createThread(th, freshThreadBody)
    joinThread(th)
    check $cast[cstring](addr gFreshThreadError[0]) == ""
