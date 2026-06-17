## Cross-platform CBOR-over-socket client for the timer IPC server.
##
## Speaks a simple length-prefixed CBOR framing (see the frame layout below) and uses chronos for
## the socket so it builds and runs on Linux, macOS and Windows. It does not
## link the library — it only needs the CBOR codec to build requests and read
## replies (exactly what a remote client has).
##
##   client tcp:127.0.0.1:9099       # any platform
##   client unix:/tmp/timer.sock     # POSIX
##
## Exits 0 only if the round-trip values match the expectations, so it doubles
## as the integration check the CI driver runs.
import std/[os, strutils]
import chronos
import chronos/transports/stream
import results
import ffi/cbor_serial

# Local mirrors of the wire shapes (a remote client defines its own — it never
# imports the library). Field names match the generated CBOR ABI.
type
  EchoReqWire = object
    message: string
    delayMs: int
  EchoReqEnv = object
    req: EchoReqWire
  EchoRespWire = object
    echoed: string
    timerName: string

proc writeU32(t: StreamTransport, v: uint32) {.async.} =
  let b = @[byte(v shr 24), byte(v shr 16), byte(v shr 8), byte(v and 0xFF)]
  discard await t.write(b)

proc readU32(t: StreamTransport): Future[uint32] {.async.} =
  var b: array[4, byte]
  await t.readExactly(addr b[0], 4)
  return
    (uint32(b[0]) shl 24) or (uint32(b[1]) shl 16) or (uint32(b[2]) shl 8) or
    uint32(b[3])

proc call(
    t: StreamTransport, meth: string, payload: seq[byte]
): Future[(int32, seq[byte])] {.async.} =
  # Request frame: [u32 method_len][method][u32 payload_len][payload].
  await writeU32(t, uint32(meth.len))
  if meth.len > 0:
    discard await t.write(meth)
  await writeU32(t, uint32(payload.len))
  if payload.len > 0:
    discard await t.write(payload)
  # Response frame: [i32 ret][u32 len][body].
  let ret = cast[int32](await readU32(t))
  let blen = await readU32(t)
  var body = newSeq[byte](int(blen))
  if blen > 0'u32:
    await t.readExactly(addr body[0], int(blen))
  return (ret, body)

proc parseAddress(a: string): TransportAddress =
  if a.startsWith("unix:"):
    return initTAddress(a[5 ..^ 1])
  elif a.startsWith("tcp:"):
    let hp = a[4 ..^ 1]
    let sep = hp.rfind(':')
    doAssert sep > 0, "tcp address must be tcp:<host>:<port>"
    return initTAddress(hp[0 ..< sep], Port(parseInt(hp[sep + 1 ..^ 1])))
  else:
    raise newException(ValueError, "address must be unix:<path> or tcp:<host>:<port>")

proc connectWithRetry(ta: TransportAddress): Future[StreamTransport] {.async.} =
  # The server may still be starting; retry briefly so the example/CI is not
  # racing socket setup.
  for _ in 0 ..< 100:
    try:
      return await connect(ta)
    except CatchableError:
      await sleepAsync(50.milliseconds)
  return await connect(ta) # last attempt: surface the real error

proc run(address: string): Future[bool] {.async.} =
  let t = await connectWithRetry(parseAddress(address))
  var ok = true
  echo "[client] connected"

  # 1) version — empty request, response is a CBOR text string.
  block:
    let (ret, body) = await t.call("version", @[byte 0xA0]) # empty CBOR map {}
    let v = cborDecode(body, string)
    if ret == 0 and v.isOk:
      echo "[client] version    = ", v.get()
      ok = ok and v.get() == "nim-timer v0.1.0"
    else:
      echo "[client] version failed (ret=", ret, ")"
      ok = false

  # 2) echo — nested request, response is an EchoResponse map.
  block:
    let req = cborEncode(EchoReqEnv(req: EchoReqWire(message: "hello over the wire", delayMs: 5)))
    let (ret, body) = await t.call("echo", req)
    let r = cborDecode(body, EchoRespWire)
    if ret == 0 and r.isOk:
      echo "[client] echo.echoed= ", r.get().echoed
      echo "[client] echo.timer = ", r.get().timerName
      ok = ok and r.get().echoed == "hello over the wire" and r.get().timerName == "ipc-server"
    else:
      echo "[client] echo failed (ret=", ret, ")"
      ok = false

  await t.closeWait()
  echo "[client] done"
  return ok

when isMainModule:
  if paramCount() != 1:
    stderr.writeLine "usage: client <tcp:host:port | unix:path>"
    quit(2)
  quit(if waitFor run(paramStr(1)): 0 else: 1)
