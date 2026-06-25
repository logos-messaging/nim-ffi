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
var gCompleted: Atomic[int] ## bumped once per callback; also the callback userData
var gSendErrors: Atomic[int]

let settleTimeout = 30.seconds

## Forcing gate: min submit-throughput scaling (max-threads / 1-thread); red
## until the per-request submit lock is replaced. See README "Scaling gate".
const RequiredScaling = 1.5

proc benchCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let counter = cast[ptr Atomic[int]](userData)
  discard counter[].fetchAdd(1)

type ProducerArg = object
  ctx: ptr FFIContext[BenchLib]
  count: int

proc producerBody(arg: ptr ProducerArg) {.thread, gcsafe.} =
  while not gStart.load():
    discard
  for _ in 0 ..< arg[].count:
    let req = NoopRequest.ffiNewReq(benchCallback, addr gCompleted)
    if sendRequestToFFIThread(arg[].ctx, req).isErr():
      discard gSendErrors.fetchAdd(1)

proc waitForCompletions(target: int): bool =
  ## Spins until `gCompleted` reaches `target`, bounded by `settleTimeout`.
  let deadline = Moment.now() + settleTimeout
  while gCompleted.load() < target:
    if Moment.now() > deadline:
      return false
    os.sleep(1)
  true

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
  overruns: int ## callbacks beyond `total` — must be 0 (no double-fire)

proc runOnce(
    pool: var FFIContextPool[BenchLib], numThreads, perThread: int
): IterResult =
  let ctx = pool.createFFIContext().valueOr:
    quit("createFFIContext failed: " & $error)
  defer:
    discard pool.destroyFFIContext(ctx)

  let total = numThreads * perThread
  gStart.store(false)
  gCompleted.store(0)
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

  if not waitForCompletions(total):
    quit("timed out waiting for callbacks: got " & $gCompleted.load() & " of " & $total)
  os.sleep(50) # let any erroneous extra callbacks land before reading overruns

  IterResult(
    submitRate: total.float / submitSec,
    sendErrors: gSendErrors.load(),
    overruns: max(0, gCompleted.load() - total),
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
  # CI default is a light sweep so the gate and the (far slower) asan/tsan jobs
  # stay fast; the high-contention curve (e.g. up to 100 threads) is opt-in for
  # local on-demand runs via FFI_SUBMIT_THREADS. A heavy sweep under a sanitizer
  # on a slow runner can't settle its callbacks within `settleTimeout` and would
  # fail on a timeout, not a real bug — so it is kept out of CI deliberately.
  #   FFI_SUBMIT_THREADS="1,8,16,32,64,100" nimble bench_ffi_submit
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
      echo "  !! ", overruns, " callbacks fired beyond expected at ", n, " threads"
      allPassed = false

  if not allPassed:
    quit("stress test FAILED: see !! lines above")
  echo ""
  echo "  correctness: callback count matched submits exactly (no drops/dupes)."

  if gateOn:
    enforceScalingGate(medianRate)

when isMainModule:
  main()
