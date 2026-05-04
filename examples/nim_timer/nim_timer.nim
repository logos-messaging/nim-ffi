import ffi, chronos, options

type Maybe[T] = Option[T]

declareLibrary("nimtimer")

# The library's main state type. The FFI context owns one instance.
type NimTimer = object
  name: string # set at creation time, read back in each response

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

# --- Constructor -----------------------------------------------------------
# Called once from Rust. Creates the FFIContext + NimTimer.
# Uses chronos (await sleepAsync) so the body is async.
proc nimtimerCreate*(
    config: TimerConfig
): Future[Result[NimTimer, string]] {.ffiCtor.} =
  await sleepAsync(1.milliseconds) # proves chronos is live on the FFI thread
  return ok(NimTimer(name: config.name))

# --- Async method ----------------------------------------------------------
# Waits `delayMs` milliseconds (non-blocking, on the chronos event loop)
# then echoes the message back with a request counter.
proc nimtimerEcho*(
    timer: NimTimer, req: EchoRequest
): Future[Result[EchoResponse, string]] {.ffi.} =
  await sleepAsync(req.delayMs.milliseconds)
  return ok(EchoResponse(echoed: req.message, timerName: timer.name))

# --- Sync method -----------------------------------------------------------
# No await — the macro detects this and fires the callback inline,
# without going through the request channel.
proc nimtimerVersion*(timer: NimTimer): Future[Result[string, string]] {.ffi.} =
  return ok("nim-timer v0.1.0")

proc nimtimerComplex*(
    timer: NimTimer, req: ComplexRequest
): Future[Result[ComplexResponse, string]] {.ffi.} =
  let note = if req.note.isSome: req.note.get else: "<none>"
  let retries = if req.retries.isSome: req.retries.get else: 0
  let count = req.messages.len
  let summary =
    "received " & $count & " messages, note=" & note & ", retries=" & $retries
  return
    ok(ComplexResponse(summary: summary, itemCount: count, hasNote: req.note.isSome))

# --- genBindings() must come AFTER every {.ffi.} / {.ffiCtor.} annotation ---
# Each pragma populates ffiProcRegistry / ffiTypeRegistry at compile time as
# the compiler processes the AST. genBindings() reads those registries to emit
# the binding files, so placing it any earlier would produce incomplete output.
# In a multi-file library, import all sub-modules first and call genBindings()
# once, at the bottom of the top-level compilation-root file.
# This call is a no-op unless -d:ffiGenBindings is passed to the compiler.
genBindings() # reads -d:ffiOutputDir, -d:ffiNimSrcRelPath, -d:targetLang from compile flags

proc nimtimer_destroy*(ctx: pointer) {.dynlib, exportc, cdecl, raises: [].} =
  ## Tears down the FFI context created by nimtimer_create.
  ## Blocks until the FFI thread and watchdog thread have joined.
  try:
    discard destroyFFIContext[NimTimer](cast[ptr FFIContext[NimTimer]](ctx))
  except:
    discard
