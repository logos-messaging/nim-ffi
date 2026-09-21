## Concurrent-submit stress test + throughput bench for `sendRequestToFFIThread`,
## motivating its per-request submit lock. See tests/bench/README.md for the why.

import std/[atomics, algorithm, strutils, os]
import results
import ../../ffi # chronos (Moment/Duration) and the FFI surface both arrive here.

type BenchLib = object

registerReqFFI(NoopRequest, lib: ptr BenchLib):
  proc(): Future[Result[string, string]] {.async.} =
    return ok("ok")

var gStart: Atomic[bool]
var gSendErrors: Atomic[int]

let settleTimeout = 30.seconds

## Min submit-throughput scaling gate (max-threads / 1-thread). See README.
const RequiredScaling = 1.5

type ProducerArg = object
  ctx: ptr FFIContext[BenchLib]
  count: int

proc producerBody(arg: ptr ProducerArg) {.thread, gcsafe.} =
  while not gStart.load():
    discard
  for _ in 0 ..< arg[].count:
    if sendRequestToFFIThread(arg[].ctx, NoopRequest.ffiNewReq()).isErr():
      discard gSendErrors.fetchAdd(1)

type Collected = object
  replies: int
  duplicates: int ## replies carrying an id already seen — must be 0
  extra: int ## replies beyond the accepted submits — must be 0

proc collectReplies(ctx: ptr FFIContext[BenchLib], target: int): Collected =
  ## Polls until `target` replies arrived, bounded by `settleTimeout`, then looks
  ## for one more: an accepted request is answered exactly once.
  var collected: Collected
  var ids = newSeqOfCap[uint64](target)
  let generation = ctx.currentGeneration()
  let deadline = Moment.now() + settleTimeout
  var msg: ptr NimFfiMsg
  while collected.replies < target and Moment.now() <= deadline:
    if pollContext(ctx, generation, 100, addr msg) != RET_OK:
      continue
    if msg.kind == MsgReply:
      ids.add(msg.id)
      collected.replies.inc()
  while pollContext(ctx, generation, 50, addr msg) == RET_OK:
    if msg.kind == MsgReply:
      collected.extra.inc()
  ids.sort()
  for i in 1 ..< ids.len:
    if ids[i] == ids[i - 1]:
      collected.duplicates.inc()
  return collected

proc median(xs: seq[float]): float =
  if xs.len == 0:
    return 0.0
  let s = xs.sorted()
  if s.len mod 2 == 1:
    return s[s.len div 2]
  (s[s.len div 2 - 1] + s[s.len div 2]) / 2.0

type IterResult = object
  submitRate: float ## submits/sec over the submit phase only (sends issued)
  sendErrors: int
  overruns: int ## duplicate or extra replies — must be 0 (one reply per request)

proc runOnce(
    pool: var FFIContextPool[BenchLib], numThreads, perThread: int
): IterResult =
  let ctx = pool.createFFIContext().valueOr:
    quit("createFFIContext failed: " & $error)
  defer:
    discard pool.destroyFFIContext(ctx)

  let total = numThreads * perThread
  gStart.store(false)
  gSendErrors.store(0)

  var threads = newSeq[Thread[ptr ProducerArg]](numThreads)
  var args = newSeq[ProducerArg](numThreads)
  for i in 0 ..< numThreads:
    args[i] = ProducerArg(ctx: ctx, count: perThread)
    createThread(threads[i], producerBody, addr args[i])

  # Times the lock-serialised submit path only; completion (single FFI thread) is excluded.
  let start = Moment.now()
  gStart.store(true)
  joinThreads(threads)
  let submitSec = (Moment.now() - start).nanoseconds.float / 1_000_000_000.0

  # A refused submit gets no reply, so collect only the accepted ones. Nobody
  # polls during the submit phase: the replies wait, which is what the raised
  # `ffiMaxOutstandingRequests` in the sibling .cfg allows.
  let sendErrors = gSendErrors.load()
  let accepted = total - sendErrors
  let collected = collectReplies(ctx, accepted)
  if collected.replies < accepted:
    quit("timed out polling replies: got " & $collected.replies & " of " & $accepted)

  IterResult(
    submitRate: total.float / submitSec,
    sendErrors: sendErrors,
    overruns: collected.duplicates + collected.extra,
  )

proc enforceScalingGate(medianRate: seq[float]) =
  ## Fails the process when submit throughput doesn't scale past RequiredScaling.
  let scalingMax = medianRate[^1] / medianRate[0]
  echo ""
  if scalingMax < RequiredScaling:
    quit(
      "SCALING GATE: submit scaling " & formatFloat(scalingMax, ffDecimal, 2) &
        "x < required " & formatFloat(RequiredScaling, ffDecimal, 2) &
        "x. The per-request global lock serialises every submit; replace it with " &
        "MPSC ingress (see tests/bench/README.md) to make this pass."
    )
  echo "  scaling gate: ",
    formatFloat(scalingMax, ffDecimal, 2),
    "x >= ",
    formatFloat(RequiredScaling, ffDecimal, 2),
    "x — submit path scales."

proc main() =
  let perThread = parseInt(getEnv("FFI_SUBMIT_PER_THREAD", "20000"))
  let iters = parseInt(getEnv("FFI_SUBMIT_ITERS", "5"))
  let gateOn = getEnv("FFI_SCALING_GATE", "1") != "0"
  if perThread < 1 or iters < 1:
    quit("FFI_SUBMIT_PER_THREAD and FFI_SUBMIT_ITERS must be >= 1")
  # Default sweep is light so CI stays fast; set FFI_SUBMIT_THREADS locally for the high-contention curve.
  let threadCounts = block:
    var cs: seq[int]
    for part in getEnv("FFI_SUBMIT_THREADS", "1,2,4,8").split(','):
      let p = part.strip()
      if p.len > 0:
        cs.add(parseInt(p))
    if cs.len < 2:
      quit("FFI_SUBMIT_THREADS needs >= 2 counts (first = baseline, last = peak)")
    cs

  echo "── sendRequestToFFIThread submit throughput (median of ",
    iters, ") ──────"
  echo "  ", perThread, " submits per producer thread; noop handler (ok(\"ok\"))"
  echo ""
  echo "  ",
    alignLeft("threads", 9),
    alignLeft("submits", 10),
    alignLeft("submit/sec", 16),
    alignLeft("vs 1-thread", 12)

  var pool: FFIContextPool[BenchLib]
  var medianRate: seq[float]
  var allPassed = true
  for n in threadCounts:
    var rates: seq[float]
    var sendErrors = 0
    var overruns = 0
    for _ in 0 ..< iters:
      let r = runOnce(pool, n, perThread)
      rates.add(r.submitRate)
      sendErrors += r.sendErrors
      overruns += r.overruns
    let med = median(rates)
    medianRate.add(med)
    echo "  ",
      alignLeft($n, 9),
      alignLeft($(n * perThread), 10),
      alignLeft(formatFloat(med, ffDecimal, 0), 16),
      alignLeft(formatFloat(med / medianRate[0], ffDecimal, 2) & "x", 12)

    if sendErrors != 0:
      echo "  !! ", sendErrors, " submit errors at ", n, " threads"
      allPassed = false
    if overruns != 0:
      echo "  !! ", overruns, " duplicate or extra replies at ", n, " threads"
      allPassed = false

  if not allPassed:
    quit("stress test FAILED: see !! lines above")
  echo ""
  echo "  correctness: reply count matched submits exactly (no drops/dupes)."

  if gateOn:
    enforceScalingGate(medianRate)

when isMainModule:
  main()
