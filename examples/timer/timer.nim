import ffi, chronos, options

type Maybe[T] = Option[T]

# Named `MyTimer` (not `Timer`) so C symbols like `my_timer_create` don't collide with POSIX `<time.h>`'s `timer_create`.
type MyTimer = object
  name: string # set at creation time, read back in each response

# `defaultABIFormat` is the wire format every annotation inherits (override per-annotation with "abi = ...").
declareLibrary("my_timer", MyTimer, defaultABIFormat = "cbor")

# {.ffiConst.}: re-emitted as a native constant in every binding.
const
  MaxDelayMs* {.ffiConst.} = 5_000
  DefaultBackoffMs* {.ffiConst.}: uint32 = 250
  TimerVersion* {.ffiConst.} = "nim-timer v0.1.0"

type TimerConfig {.ffi.} = object
  name: string

type EchoRequest {.ffi.} = object
  message: string
  delayMs: int # how long chronos sleeps before replying

type EchoResponse {.ffi.} = object
  echoed: string
  timerName: string # proves that the timer's own state is accessible

type ComplexRequest {.ffi.} = object
  messages: seq[EchoRequest]
  tags: seq[string]
  note: Option[string]
  retries: Maybe[int]

type ComplexResponse {.ffi.} = object
  summary: string
  itemCount: int
  hasNote: bool

# {.ffiEvent.}: a typed event any {.ffi.} handler can fire to the foreign callback.
type EchoEvent {.ffi.} = object
  message: string
  echoCount: int

proc onEchoFired*(evt: EchoEvent) {.ffiEvent: "on_echo_fired".} =
  ## Fired by `myTimerEcho` once the reply is ready.

proc myTimerCreate*(config: TimerConfig): Future[Result[MyTimer, string]] {.ffiCtor.} =
  ## Creates the FFIContext + MyTimer; async via chronos.
  await sleepAsync(1.milliseconds) # proves chronos is live on the FFI thread
  return ok(MyTimer(name: config.name))

proc myTimerEcho*(
    timer: MyTimer, req: EchoRequest
): Future[Result[EchoResponse, string]] {.ffi.} =
  ## Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`.
  if req.delayMs > MaxDelayMs:
    return err("delayMs must not exceed " & $MaxDelayMs)
  await sleepAsync(req.delayMs.milliseconds)
  onEchoFired(EchoEvent(message: req.message, echoCount: 1))
  return ok(EchoResponse(echoed: req.message, timerName: timer.name))

# Sync method: no await, so the macro fires the callback inline.
proc myTimerVersion*(timer: MyTimer): Future[Result[string, string]] {.ffi.} =
  ## Returns the library's version string.
  return ok(TimerVersion)

proc myTimerComplex*(
    timer: MyTimer, req: ComplexRequest
): Future[Result[ComplexResponse, string]] {.ffi.} =
  let note = if req.note.isSome: req.note.get else: "<none>"
  let retries = if req.retries.isSome: req.retries.get else: 0
  let count = req.messages.len
  let summary =
    "received " & $count & " messages, note=" & note & ", retries=" & $retries
  return
    ok(ComplexResponse(summary: summary, itemCount: count, hasNote: req.note.isSome))

# {.ffi.} on an enum: a native enum in every binding, crossing the wire as text.
type JobPriority {.ffi.} = enum
  jpLow = "low"
  jpNormal = "normal"
  jpHigh = "high"

# Multiple object-typed params: each is its own {.ffi.} type, all carried in one per-proc Req envelope.
type JobSpec {.ffi.} = object
  name: string
  payload: seq[string]
  priority: JobPriority

type RetryPolicy {.ffi.} = object
  maxAttempts: int
  backoffMs: int
  retryOn: seq[string] # error keywords that should trigger a retry

type ScheduleConfig {.ffi.} = object
  startAtMs: int
  intervalMs: int # 0 means "fire once"
  jitter: Option[int]

type ScheduleResult {.ffi.} = object
  jobId: string
  willRunCount: int
  firstRunAtMs: int
  effectiveBackoffMs: int
  priority: JobPriority

func effectiveBackoff(priority: JobPriority, backoffMs: int): int =
  let base = if backoffMs > 0: backoffMs else: DefaultBackoffMs.int
  case priority
  of jpHigh:
    return base div 2
  of jpNormal:
    return base
  of jpLow:
    return base * 2

proc myTimerSchedule*(
    timer: MyTimer, job: JobSpec, retry: RetryPolicy, schedule: ScheduleConfig
): Future[Result[ScheduleResult, string]] {.ffi.} =
  ## Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
  await sleepAsync(1.milliseconds)
  if job.name.len == 0:
    return err("job name must not be empty")
  if retry.maxAttempts <= 0:
    return err("retry.maxAttempts must be positive")
  let willRunCount =
    if schedule.intervalMs > 0:
      max(1, 60_000 div schedule.intervalMs) # rough "runs per minute"
    else:
      1
  let jitter = if schedule.jitter.isSome: schedule.jitter.get else: 0
  return ok(
    ScheduleResult(
      jobId: timer.name & ":" & job.name,
      willRunCount: willRunCount,
      firstRunAtMs: schedule.startAtMs + jitter,
      effectiveBackoffMs: effectiveBackoff(job.priority, retry.backoffMs),
      priority: job.priority,
    )
  )

proc my_timer_destroy*(timer: MyTimer) {.ffiDtor.} =
  ## Tears down the FFI context; blocks until FFI + watchdog threads join.
  discard

# Must be the LAST top-level call, after every pragma registered its proc (no-op unless -d:ffiGenBindings).
genBindings()
