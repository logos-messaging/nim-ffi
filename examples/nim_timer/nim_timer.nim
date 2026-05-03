import ffi, chronos

declareLibrary("nimtimer")

# The library's main state type. The FFI context owns one instance.
type NimTimer = object
  name: string  # set at creation time, read back in each response

ffiType:
  type TimerConfig = object
    name: string

ffiType:
  type EchoRequest = object
    message: string
    delayMs: int  # how long chronos sleeps before replying

ffiType:
  type EchoResponse = object
    echoed: string
    timerName: string  # proves that the timer's own state is accessible

# --- Constructor -----------------------------------------------------------
# Called once from Rust. Creates the FFIContext + NimTimer.
# Uses chronos (await sleepAsync) so the body is async.
proc nimtimer_create*(
    config: TimerConfig
): Future[Result[NimTimer, string]] {.ffiCtor.} =
  await sleepAsync(1.milliseconds)  # proves chronos is live on the FFI thread
  return ok(NimTimer(name: config.name))

# --- Async method ----------------------------------------------------------
# Waits `delayMs` milliseconds (non-blocking, on the chronos event loop)
# then echoes the message back with a request counter.
proc nimtimer_echo*(
    timer: NimTimer, req: EchoRequest
): Future[Result[EchoResponse, string]] {.ffi.} =
  await sleepAsync(req.delayMs.milliseconds)
  return ok(EchoResponse(echoed: req.message, timerName: timer.name))

# --- Sync method -----------------------------------------------------------
# No await — the macro detects this and fires the callback inline,
# without going through the request channel.
proc nimtimer_version*(
    timer: NimTimer
): Future[Result[string, string]] {.ffi.} =
  return ok("nim-timer v0.1.0")

when defined(ffiGenBindings):
  genBindings("examples/nim_timer/nim_bindings", "../nim_timer.nim")
