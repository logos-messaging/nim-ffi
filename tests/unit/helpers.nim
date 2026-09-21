## Shared harness for the unit tests: request plumbing, wait loops and the
## watchdog. Not named `test_*`, so `discoverUnitTests` does not run it.

import std/[atomics, locks, os]
import ffi

proc encodedPtr*(bytes: var seq[byte]): ptr byte =
  ## `addr bytes[0]` is a defect on an empty seq, and a request may carry none.
  if bytes.len == 0:
    nil
  else:
    cast[ptr byte](addr bytes[0])

proc waitFlag*(flag: var Atomic[bool], timeoutMs = 5000): bool =
  let deadline = Moment.now() + timeoutMs.milliseconds
  while not flag.load():
    if Moment.now() >= deadline:
      return false
    os.sleep(5)
  true

proc waitSlotFree*[T](ctx: ptr FFIContext[T]) =
  ## Waits out the claim of a recycle driven elsewhere; `recycleFFIContext` returns with it free.
  let deadline = Moment.now() + 5.seconds
  while ctx.isInUse() and Moment.now() < deadline:
    os.sleep(1)

type PolledMsg* = object
  ## One `poll` result, with the payload copied out: the library's copy dies at the next poll.
  ret*: cint
  kind*: uint32
  seq*: uint64
  id*: uint64
  nameId*: uint64
  aux*: uint64
  retCode*: int32
  payload*: seq[byte]

proc pollMsg*[T](
    ctx: ptr FFIContext[T], generation: uint, timeoutMs = 5000
): PolledMsg =
  var msg: ptr NimFfiMsg
  let ret = pollContext(ctx, generation, timeoutMs, addr msg)
  var polled = PolledMsg(ret: ret)
  if msg.isNil():
    return polled
  polled.kind = msg.kind
  polled.seq = msg.seq
  polled.id = msg.id
  polled.nameId = msg.nameId
  polled.aux = msg.aux
  polled.retCode = msg.retCode
  polled.payload = newSeq[byte](int(msg.len))
  if msg.len > 0:
    copyMem(addr polled.payload[0], msg.payload, int(msg.len))
  return polled

proc pollMsg*[T](ctx: ptr FFIContext[T], timeoutMs = 5000): PolledMsg =
  return pollMsg(ctx, ctx.currentGeneration(), timeoutMs)

type SkippedMsg = object
  ctx: pointer
  generation: uint
  msg: PolledMsg

var skipped {.threadvar.}: seq[SkippedMsg]
  ## What `pollReply` polled on its way to the reply it wanted; `nextMsg` hands them
  ## out first. Tagged with the claim, so one owner's leftovers never reach the next.

proc takeSkipped[T](
    ctx: ptr FFIContext[T], wanted: proc(m: PolledMsg): bool, found: var PolledMsg
): bool =
  for i in 0 ..< skipped.len:
    if skipped[i].ctx == cast[pointer](ctx) and
        skipped[i].generation == ctx.currentGeneration() and wanted(skipped[i].msg):
      found = skipped[i].msg
      skipped.delete(i)
      return true
  return false

proc nextMsg*[T](ctx: ptr FFIContext[T], timeoutMs = 5000): PolledMsg =
  ## `pollMsg` for a test that also uses `pollReply`: no message is lost between them.
  var first: PolledMsg
  if takeSkipped(
    ctx,
    proc(m: PolledMsg): bool =
      true,
    first,
  ):
    return first
  return pollMsg(ctx, timeoutMs)

proc pollReply*[T](ctx: ptr FFIContext[T], reqId: uint64, timeoutMs = 5000): PolledMsg =
  ## The reply of `reqId`. Stale warnings about it are dropped; every other message
  ## is kept for `nextMsg`. `ret` is `RET_TIMEOUT` when it does not come in time.
  var found: PolledMsg
  if takeSkipped(
    ctx,
    proc(m: PolledMsg): bool =
      m.kind == MsgReply and m.id == reqId,
    found,
  ):
    return found
  let deadline = Moment.now() + timeoutMs.milliseconds
  while true:
    let left = (deadline - Moment.now()).milliseconds
    if left <= 0:
      return PolledMsg(ret: RET_TIMEOUT)
    let got = pollMsg(ctx, int(left))
    if got.ret != RET_OK:
      return got
    if got.kind == MsgReply and got.id == reqId:
      return got
    if got.kind == MsgStaleWarn and got.id == reqId:
      continue
    skipped.add(
      SkippedMsg(ctx: cast[pointer](ctx), generation: ctx.currentGeneration(), msg: got)
    )

proc text*(m: PolledMsg): string =
  ## The payload as text: the error of a RET_ERR reply.
  var s = newString(m.payload.len)
  if m.payload.len > 0:
    copyMem(addr s[0], unsafeAddr m.payload[0], m.payload.len)
  return s

proc okString*(m: PolledMsg): string =
  ## The CBOR-decoded `string` an OK reply carries; asserts the request succeeded,
  ## so a failure reports the error text instead of an empty string.
  doAssert m.ret == RET_OK and m.retCode == RET_OK,
    "okString on ret " & $m.ret & " retCode " & $m.retCode & " (msg=" & m.text() & ")"
  return cborDecode(m.payload, string).valueOr:
    ""

proc call*[T](
    ctx: ptr FFIContext[T], request: ptr FFIThreadRequest, timeoutMs = 5000
): PolledMsg =
  ## Submits `request` and waits for its reply.
  let reqId = sendRequestToFFIThread(ctx, request).valueOr:
    return PolledMsg(ret: RET_ERR, retCode: RET_ERR, payload: cast[seq[byte]](error))
  return pollReply(ctx, reqId, timeoutMs)

proc waitReplyQueued*[T](ctx: ptr FFIContext[T], timeoutMs = 5000): bool =
  ## Looks without polling: for a test where polling would change what it observes,
  ## or where another thread is the poller.
  let deadline = Moment.now() + timeoutMs.milliseconds
  while true:
    var queued = false
    withLock ctx[].outbound.lock:
      queued = not ctx[].outbound.replyHead.isNil()
    if queued:
      return true
    if Moment.now() >= deadline:
      return false
    os.sleep(2)

proc watchdogBody(args: (int, cstring)) {.thread.} =
  os.sleep(args[0])
  echo "watchdog: ", args[1]
  quit(1)

var watchdog: Thread[(int, cstring)]

proc startWatchdog*(timeoutMs: int, message: cstring) =
  ## For a file whose unpatched behaviour is a hang: the process must die on its
  ## own, or CI blocks instead of failing.
  createThread(watchdog, watchdogBody, (timeoutMs, message))
