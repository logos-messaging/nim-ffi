## Listener-lifetime e2e fixture: an event loop, and a teardown that can overrun its timeout.

import ffi, chronos

type Ticker = ref object
  loop: Future[void]
  stallTeardown: bool

declareLibrary("ticker", Ticker)

type TickerConfig {.ffi.} = object
  stallTeardown: bool

type Tick {.ffi.} = object
  count: int

proc onTick*(tick: Tick) {.ffiEvent: "on_tick".} =
  ## Fired by the loop that `tickerStart` spawns.

proc tickLoop(intervalMs: int) {.async.} =
  var count = 0
  while true:
    count.inc()
    onTick(Tick(count: count))
    await sleepAsync(intervalMs.milliseconds)

proc tickerCreate*(config: TickerConfig): Future[Result[Ticker, string]] {.ffiCtor.} =
  return ok(Ticker(stallTeardown: config.stallTeardown))

proc tickerStart*(
    ticker: Ticker, intervalMs: int
): Future[Result[bool, string]] {.ffi.} =
  ## Spawns the tick loop on the FFI thread.
  ticker.loop = tickLoop(intervalMs)
  return ok(true)

proc ticker_destroy*(ticker: Ticker): Future[void] {.ffiDtor.} =
  ## A stalled teardown outlives the teardown timeout and leaves the loop running, so the destroy fails while events still fire.
  if ticker.stallTeardown:
    await sleepAsync(TeardownTimeout + 60.seconds)
  if not ticker.loop.isNil():
    await ticker.loop.cancelAndWait()

genBindings()
