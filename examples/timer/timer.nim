import ffi, chronos, options

type Maybe[T] = Option[T]

# The library's main state type. The FFI context owns one instance.
# Named `MyTimer` (not `Timer`) so the C-exported symbols are
# `my_timer_create` / `my_timer_destroy` / ... — `timer_create` would
# collide with POSIX `<time.h>`'s `int timer_create(clockid_t, ...)` which
# `<pthread.h>` transitively drags in on Linux.
type MyTimer = object
  name: string # set at creation time, read back in each response

declareLibrary("my_timer", MyTimer)

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

# --- Library-initiated event ----------------------------------------------
# Demonstrates the {.ffiEvent.} macro: a typed event the library can fire
# from any {.ffi.} handler, dispatched to the foreign side's registered
# callback as CBOR. Per-target codegens emit a typed handler-struct +
# dispatcher so the foreign caller decodes nothing by hand.
type EchoEvent {.ffi.} = object
  message: string
  echoCount: int

proc onEchoFired*(evt: EchoEvent) {.ffiEvent: "on_echo_fired".}

# --- Constructor -----------------------------------------------------------
# Called once from Rust. Creates the FFIContext + MyTimer.
# Uses chronos (await sleepAsync) so the body is async.
proc myTimerCreate*(config: TimerConfig): Future[Result[MyTimer, string]] {.ffiCtor.} =
  await sleepAsync(1.milliseconds) # proves chronos is live on the FFI thread
  return ok(MyTimer(name: config.name))

# --- Async method ----------------------------------------------------------
# Waits `delayMs` milliseconds (non-blocking, on the chronos event loop)
# then echoes the message back with a request counter.
proc myTimerEcho*(
    timer: MyTimer, req: EchoRequest
): Future[Result[EchoResponse, string]] {.ffi.} =
  await sleepAsync(req.delayMs.milliseconds)
  onEchoFired(EchoEvent(message: req.message, echoCount: 1))
  return ok(EchoResponse(echoed: req.message, timerName: timer.name))

# --- Sync method -----------------------------------------------------------
# No await — the macro detects this and fires the callback inline,
# without going through the request channel.
proc myTimerVersion*(timer: MyTimer): Future[Result[string, string]] {.ffi.} =
  return ok("nim-timer v0.1.0")

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

# --- Multiple complex parameters -------------------------------------------
# Demonstrates how a {.ffi.} proc handles several object-typed parameters at
# once. Each parameter is its own {.ffi.} type, so it lands in the generated
# foreign-side bindings as a first-class struct/class, and the per-proc Req
# envelope (MyTimerScheduleReq on the wire) carries all three under field
# names that match the Nim params.
type JobSpec {.ffi.} = object
  name: string
  payload: seq[string]
  priority: int # higher = runs sooner

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

proc myTimerSchedule*(
    timer: MyTimer, job: JobSpec, retry: RetryPolicy, schedule: ScheduleConfig
): Future[Result[ScheduleResult, string]] {.ffi.} =
  ## Composes three independent object-typed parameters (`job`, `retry`,
  ## `schedule`) into a single scheduling decision. The macro packs them into
  ## one CBOR-encoded request envelope on the wire and unpacks them back into
  ## the named locals before this body runs.
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
      effectiveBackoffMs: retry.backoffMs,
    )
  )

proc my_timer_destroy*(timer: MyTimer) {.ffiDtor.} =
  ## Tears down the FFI context created by my_timer_create.
  ## Blocks until the FFI thread and watchdog thread have joined.
  discard

# Optional in-library CBOR-over-socket server (the "remote channel"). Compiled
# in only with -d:ffiIpcServe so every other build is unaffected; it reuses the
# async procs above directly. See examples/timer/ipc_chronos/serve.nim.
when defined(ffiIpcServe):
  include "ipc_chronos/serve.nim"

# genBindings() must be the LAST top-level call in the FFI root file —
# after every {.ffi.}, {.ffiCtor.} and {.ffiDtor.} pragma. Each pragma
# fires at compile time and registers its proc into the compile-time
# ffiProcRegistry / ffiTypeRegistry; genBindings() then reads those
# registries to emit the language bindings. If genBindings() runs before
# a pragma, that proc is silently absent from the generated bindings.
#
# Multi-file libraries: keep all .ffi./.ffiCtor./.ffiDtor. pragmas in
# imported sub-modules and call genBindings() once at the bottom of the
# top-level file that imports them — Nim resolves imports before the
# importing file's body runs, so the registries are fully populated by
# the time genBindings() executes.
#
# genBindings() is a compile-time no-op unless -d:ffiGenBindings is set.
genBindings()
