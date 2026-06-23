## Microbenchmark comparing the `cbor` and `c` (cwire) codecs on identical
## payloads in one process, isolating codec cost from the thread/callback hop.

import std/[monotimes, options, os, strformat, strutils, times]
import ../../ffi

# Payload types mirror the timer example so e2e and bench stay comparable.

type EchoRequest {.ffi: "abi = c".} = object
  message: string
  delayMs: int

type EchoResponse {.ffi: "abi = c".} = object
  echoed: string
  timerName: string

type ComplexRequest {.ffi: "abi = c".} = object
  messages: seq[EchoRequest]
  tags: seq[string]
  note: Option[string]
  retries: Option[int]

type BytesPayload {.ffi: "abi = c".} = object
  payload: seq[byte]

# Flush the cwire companions for the types above.
genBindings()

const Iterations = 200_000
const HeaderWidth = 66

proc reportTiming(label: string, perOp: float, iters: int) =
  let padded = label & repeat(' ', max(0, 46 - label.len()))
  echo "  " & padded & " " & formatFloat(perOp, ffDecimal, 2) & " ns/op  (" & $iters &
    " iters)"

template timeItN(labelArg: string, iters: int, body: untyped): float =
  ## Returns nanoseconds per iteration averaged over `iters`.
  let start = getMonoTime()
  for i in 0 ..< iters:
    body
  let elapsed = (getMonoTime() - start).inNanoseconds.float
  let perOp = elapsed / iters.float
  reportTiming(labelArg, perOp, iters)
  perOp

template timeIt(labelArg: string, body: untyped): float =
  timeItN(labelArg, Iterations, body)

proc mibPerSec(sizeBytes: int, perOpNs: float): float =
  (sizeBytes.float / perOpNs) * 1_000_000_000.0 / (1024.0 * 1024.0)

proc benchEchoRequest() =
  echo "── EchoRequest (small: 1 string + 1 int) ─────────────────────────"
  let req = EchoRequest(message: "hello world", delayMs: 100)

  let cborRtNs = timeIt "cbor encode + decode":
    let bytes = cborEncode(req)
    let back = cborDecode(bytes, EchoRequest).valueOr:
      doAssert false, error
      default(EchoRequest)
    doAssert back.delayMs == 100

  let cwireRtNs = timeIt "cwire pack + unpack + free":
    var wire: EchoRequest_CWire
    cwirePack(wire, req)
    let back = cwireUnpack(wire)
    doAssert back.delayMs == 100
    cwireFree(wire)

  echo &"  ratio (cbor RT / cwire RT) = {cborRtNs / cwireRtNs:.2f}x"
  echo ""

proc benchEchoResponse() =
  echo "── EchoResponse (small: 2 strings) ───────────────────────────────"
  let resp = EchoResponse(echoed: "hello world", timerName: "bench-timer")

  let cborRtNs = timeIt "cbor encode + decode":
    let bytes = cborEncode(resp)
    let back = cborDecode(bytes, EchoResponse).valueOr:
      doAssert false, error
      default(EchoResponse)
    doAssert back.timerName == "bench-timer"

  let cwireRtNs = timeIt "cwire pack + unpack + free":
    var wire: EchoResponse_CWire
    cwirePack(wire, resp)
    let back = cwireUnpack(wire)
    doAssert back.timerName == "bench-timer"
    cwireFree(wire)

  echo &"  ratio (cbor RT / cwire RT) = {cborRtNs / cwireRtNs:.2f}x"
  echo ""

proc benchComplexRequest() =
  echo "── ComplexRequest (seq[EchoRequest] x4, seq[string] x3, options) ─"
  let req = ComplexRequest(
    messages: @[
      EchoRequest(message: "alpha", delayMs: 1),
      EchoRequest(message: "beta", delayMs: 2),
      EchoRequest(message: "gamma", delayMs: 3),
      EchoRequest(message: "delta", delayMs: 4),
    ],
    tags: @["fast", "async", "bench"],
    note: some("a slightly longer note that survives the round-trip"),
    retries: some(7),
  )

  let cborRtNs = timeIt "cbor encode + decode":
    let bytes = cborEncode(req)
    let back = cborDecode(bytes, ComplexRequest).valueOr:
      doAssert false, error
      default(ComplexRequest)
    doAssert back.messages.len() == 4

  let cwireRtNs = timeIt "cwire pack + unpack + free":
    var wire: ComplexRequest_CWire
    cwirePack(wire, req)
    let back = cwireUnpack(wire)
    doAssert back.messages.len() == 4
    cwireFree(wire)

  echo &"  ratio (cbor RT / cwire RT) = {cborRtNs / cwireRtNs:.2f}x"
  echo ""

proc benchBytesAtSize(sizeBytes: int, iters: int) =
  # Iteration count scales down with size: a 1 MiB op costs ~100s of µs.
  let label = "── BytesPayload (seq[byte], " & $sizeBytes & " bytes) "
  echo label & repeat('-', max(0, HeaderWidth - label.len()))
  var blob = newSeq[byte](sizeBytes)
  for i in 0 ..< sizeBytes:
    blob[i] = byte(i and 0xff)
  let req = BytesPayload(payload: blob)

  let cborRtNs = timeItN("cbor encode + decode", iters):
    let bytes = cborEncode(req)
    let back = cborDecode(bytes, BytesPayload).valueOr:
      doAssert false, error
      default(BytesPayload)
    doAssert back.payload.len() == sizeBytes

  let cwireRtNs = timeItN("cwire pack + unpack + free", iters):
    var wire: BytesPayload_CWire
    cwirePack(wire, req)
    let back = cwireUnpack(wire)
    doAssert back.payload.len() == sizeBytes
    cwireFree(wire)

  echo &"  ratio (cbor RT / cwire RT) = {cborRtNs / cwireRtNs:.2f}x" &
    &"   |   throughput  cbor={mibPerSec(sizeBytes, cborRtNs):.1f} MiB/s  cwire={mibPerSec(sizeBytes, cwireRtNs):.1f} MiB/s"
  echo ""

echo &"nim-ffi codec microbench  (cbor vs c)  {now()}"
echo "──────────────────────────────────────────────────────────────────"
echo ""
benchEchoRequest()
benchEchoResponse()
benchComplexRequest()

# Payload-size sweep across real-consumer wire caps (1 MiB is opt-in).
echo "═══ Payload-size sweep (BytesPayload.payload = seq[byte]) ═════════"
echo ""
benchBytesAtSize(100, 200_000)
benchBytesAtSize(1024, 50_000)
benchBytesAtSize(10 * 1024, 5_000)
benchBytesAtSize(64 * 1024, 500)
benchBytesAtSize(150 * 1024, 200)
if paramCount() >= 1 and paramStr(1) == "--include-1mib":
  benchBytesAtSize(1024 * 1024, 50)
