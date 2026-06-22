## Nim-level microbenchmark comparing the two FFI wire-format codecs across a
## range of payload shapes (scalars, strings, seqs, Options, nested structs,
## byte blobs):
##
##   - CBOR path:  `cborEncode(req)` + `cborDecode(bytes, T)` — self-describing
##                 bytes over `seq[byte]`, the codec the `cbor` ABI uses on
##                 every boundary crossing.
##   - cwire path: `cwirePack(dst, src)` + `cwireUnpack(src)` + `cwireFree(dst)`
##                 — flat C-struct shared-memory packing, the codec the `c` ABI
##                 uses on every boundary crossing.
##
## Both paths are timed in the same process on the same payloads, so the
## numbers isolate codec cost (no thread hop, no callback dispatch, no
## chronos work).
##
## The payload types are annotated `{.ffi: "abi = c".}` so the `c`-ABI cwire
## companion procs (`*_CWire`, `cwirePack`, `cwireUnpack`, `cwireFree`) are
## emitted; `genBindings()` at file end flushes them. The CBOR codec is generic
## and always available, so both can be timed on the same types.

import std/[monotimes, options, os, strformat, strutils, times]
import ../../ffi

# ── Payload types — mirror the timer example so the e2e and microbenches
# stay structurally comparable. -------------------------------------------

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

type ComplexResponse {.ffi: "abi = c".} = object
  summary: string
  itemCount: int
  hasNote: bool

# Single-field byte-blob type — mirrors WakuMessage.payload, codex Block.data,
# and pubsub message bodies. The size sweep below is the one suggested by
# real consumers' wire caps: 100 B (control / RPC envelopes), 1 KiB (typical
# chat), 10 KiB (fat pubsub / encrypted blob), 64 KiB (codex block), and
# 150 KiB (DefaultMaxWakuMessageSize). 1 MiB (libp2p pubsub max) is left
# out of the default sweep to keep iteration counts reasonable; pass it
# as a CLI arg to opt in.
type BytesPayload {.ffi: "abi = c".} = object
  payload: seq[byte]

# `genBindings()` here triggers the deferred cwire emission for every
# {.ffi.} type above. With `-d:ffiGenBindings` unset it does NOT write any
# header files — it only flushes runtime companion procs into the binary.
genBindings()

# ── Benchmark harness -----------------------------------------------------

const Iterations = 200_000

proc reportTiming(label: string, perOp: float, iters: int) =
  let padded = label & repeat(' ', max(0, 46 - label.len))
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

proc benchEchoSimple() =
  echo "── EchoRequest (small: 1 string + 1 int) ─────────────────────────"
  let req = EchoRequest(message: "hello world", delayMs: 100)

  let cborNs = timeIt "cbor encode":
    let bytes = cborEncode(req)
    doAssert bytes.len > 0

  let cborRtNs = timeIt "cbor encode + decode":
    let bytes = cborEncode(req)
    let back = cborDecode(bytes, EchoRequest).valueOr:
      doAssert false, error
      default(EchoRequest)
    doAssert back.delayMs == 100

  let cwirePackNs = timeIt "cwire pack + free":
    var wire: EchoRequest_CWire
    cwirePack(wire, req)
    cwireFree(wire)

  let cwireRtNs = timeIt "cwire pack + unpack + free":
    var wire: EchoRequest_CWire
    cwirePack(wire, req)
    let back = cwireUnpack(wire)
    doAssert back.delayMs == 100
    cwireFree(wire)

  echo &"  ratio (cbor RT / cwire RT) = {cborRtNs / cwireRtNs:.2f}x"
  echo ""

proc benchComplexPayload() =
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
    doAssert back.messages.len == 4

  let cwireRtNs = timeIt "cwire pack + unpack + free":
    var wire: ComplexRequest_CWire
    cwirePack(wire, req)
    let back = cwireUnpack(wire)
    doAssert back.messages.len == 4
    cwireFree(wire)

  echo &"  ratio (cbor RT / cwire RT) = {cborRtNs / cwireRtNs:.2f}x"
  echo ""

proc benchResponseDirection() =
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

proc benchBytesAtSize(sizeBytes: int, iters: int) =
  # Iteration count scales down with size — at 1 MiB the per-op cost is
  # several hundred microseconds, so 200k iters would take minutes.
  let label = "── BytesPayload (seq[byte], " & $sizeBytes & " bytes) "
  let pad = max(0, 66 - label.len)
  var rule = ""
  for _ in 0 ..< pad:
    rule.add('-')
  echo label & rule
  var blob = newSeq[byte](sizeBytes)
  for i in 0 ..< sizeBytes:
    blob[i] = byte(i and 0xff)
  let req = BytesPayload(payload: blob)

  let cborRtNs = timeItN("cbor encode + decode", iters):
    let bytes = cborEncode(req)
    let back = cborDecode(bytes, BytesPayload).valueOr:
      doAssert false, error
      default(BytesPayload)
    doAssert back.payload.len == sizeBytes

  let cwireRtNs = timeItN("cwire pack + unpack + free", iters):
    var wire: BytesPayload_CWire
    cwirePack(wire, req)
    let back = cwireUnpack(wire)
    doAssert back.payload.len == sizeBytes
    cwireFree(wire)

  let throughputCbor = (sizeBytes.float / cborRtNs) * 1_000.0 # MB/s
  let throughputCwire = (sizeBytes.float / cwireRtNs) * 1_000.0
  echo &"  ratio (cbor RT / cwire RT) = {cborRtNs / cwireRtNs:.2f}x" &
    &"   |   throughput  cbor={throughputCbor:.1f} MB/s  cwire={throughputCwire:.1f} MB/s"
  echo ""

when isMainModule:
  echo &"nim-ffi codec microbench  (cbor vs c)  {now()}"
  echo "──────────────────────────────────────────────────────────────────"
  echo ""
  benchEchoSimple()
  benchResponseDirection()
  benchComplexPayload()

  # Payload-size sweep — sizes drawn from real consumers:
  #   100 B   — RPC / control envelopes
  #   1 KiB   — typical encrypted chat message
  #   10 KiB  — fat pubsub message / encrypted blob
  #   64 KiB  — codex Block.data default
  #   150 KiB — Waku's DefaultMaxWakuMessageSize
  #   1 MiB   — libp2p pubsub maxMessageSize (off by default; opt-in)
  echo "═══ Payload-size sweep (BytesPayload.payload = seq[byte]) ═════════"
  echo ""
  benchBytesAtSize(100, 200_000)
  benchBytesAtSize(1024, 50_000)
  benchBytesAtSize(10 * 1024, 5_000) # 10 KiB
  benchBytesAtSize(64 * 1024, 500)
  benchBytesAtSize(150 * 1024, 200)
  if paramCount() >= 1 and paramStr(1) == "--include-1mib":
    benchBytesAtSize(1024 * 1024, 50)
