## Perf bench library — the Nim side of the C++ e2e perf harness
## (tests/perf/cpp/perf_driver.cpp).
##
## Every handler computes the same O(1) parity predicate, so the payload and
## scalar families differ purely in TRANSPORT cost (CBOR encode -> FFI thread
## -> decode), never in handler work. The C++ driver re-computes the predicate
## and verifies every reply, making each timed call a correctness check too.

import ffi, chronos

type Perfbench = object
  name: string

declareLibrary("perfbench", Perfbench)

type PerfbenchConfig {.ffi.} = object
  name: string

type PayloadCheckRequest {.ffi.} = object
  data: seq[byte]

type PayloadCheckResponse {.ffi.} = object
  ok: bool

type ScalarCheckRequest {.ffi.} = object
  a: int64
  b: int64
  x: float64

type ScalarCheckResponse {.ffi.} = object
  ok: bool

type TriggerPingRequest {.ffi.} = object
  count: int64
  payloadBytes: int64
  stampNs: int64 # driver-side steady_clock stamp, passed through verbatim

type TriggerPingResponse {.ffi.} = object
  emitted: int64

type PerfPingEvent {.ffi.} = object
  seqNo: int64
  stampNs: int64
  data: seq[byte]

proc onPerfPing*(evt: PerfPingEvent) {.ffiEvent: "on_perf_ping".}

# The one shared predicate — identical formula in the C++ driver
# (`parityPred`), so results are exactly predictable there.
func parityPred(a, b: int64, x: float64): bool =
  ((a + b + int64(x)) and 1) == 0

proc perfbenchCreate*(
    config: PerfbenchConfig
): Future[Result[Perfbench, string]] {.ffiCtor.} =
  ## Creates a bench context. No sleeps: handlers must add zero think time.
  return ok(Perfbench(name: config.name))

proc perfbenchPayloadCheck*(
    p: Perfbench, req: PayloadCheckRequest
): Future[Result[PayloadCheckResponse, string]] {.ffi.} =
  ## O(1) predicate over (first byte, last byte, length) — the payload bytes
  ## are never walked, so the cost measured is transport, not compute.
  if req.data.len == 0:
    return ok(PayloadCheckResponse(ok: parityPred(0, 0, 0.0)))
  return ok(
    PayloadCheckResponse(
      ok: parityPred(int64(req.data[0]), int64(req.data[^1]), float64(req.data.len))
    )
  )

proc perfbenchScalarCheck*(
    p: Perfbench, req: ScalarCheckRequest
): Future[Result[ScalarCheckResponse, string]] {.ffi.} =
  ## Scalar family: 2 x int64 + 1 x float64 in, bool out, same predicate.
  return ok(ScalarCheckResponse(ok: parityPred(req.a, req.b, req.x)))

proc perfbenchTriggerPing*(
    p: Perfbench, req: TriggerPingRequest
): Future[Result[TriggerPingResponse, string]] {.ffi.} =
  ## Fires `count` on_perf_ping events of `payloadBytes` each, passing the
  ## driver's clock stamp through so the listener can compute delivery latency
  ## inside a single clock domain.
  for i in 0 ..< req.count:
    onPerfPing(
      PerfPingEvent(seqNo: i, stampNs: req.stampNs, data: newSeq[byte](req.payloadBytes))
    )
  return ok(TriggerPingResponse(emitted: req.count))

proc perfbench_destroy*(p: Perfbench) {.ffiDtor.} =
  ## Releases the bench context.
  discard

genBindings()
