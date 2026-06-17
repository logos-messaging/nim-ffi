## In-library CBOR-over-socket server — the *remote channel* of the
## in-process/remote split.
##
## Included into `timer.nim` only under `-d:ffiIpcServe`, so it shares the
## module scope: it can build a `MyTimer` and call the library's async procs
## (`myTimerEcho`, …) **directly** — a plain Nim call, native, in-process, with
## zero serialization between the socket layer and the logic. CBOR exists only
## at the socket edge: each request is decoded, dispatched to the matching proc,
## and the result re-encoded. There is no FFI boundary and no callback bridge
## inside the server because the server *is* the library.
##
## Exposed as `my_timer_serve(address)` (C ABI) so a trivial host can start it.
## The wire framing is the simple length-prefixed format defined below (and
## mirrored by `client.nim`); a remote client needs only a CBOR codec.

import std/[os, strutils]
import chronos
import chronos/transports/stream
import results
import ffi/cbor_serial
import ffi/ffi_events

# The async procs fire library events (e.g. echo -> onEchoFired). Off the FFI
# thread that would log "event registry not set"; give this thread an empty
# registry so dispatch finds zero listeners and stays quiet. Delivering events
# to remote clients is separate, future work.
var serveEventRegistry: FFIEventRegistry

# Wire request envelopes. The field names mirror the generated CBOR request
# ABI (each `{.ffi.}` proc packs its args under their Nim parameter names), so
# the same bytes the C client builds decode straight into these.
type
  EchoReqEnv = object
    req: EchoRequest
  ComplexReqEnv = object
    req: ComplexRequest
  ScheduleReqEnv = object
    job: JobSpec
    retry: RetryPolicy
    schedule: ScheduleConfig

const
  RetOk: int32 = 0 # mirrors RET_OK / RET_ERR in my_timer_cbor.h
  RetErr: int32 = 1

proc toBytes(s: string): seq[byte] =
  var b = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr b[0], unsafeAddr s[0], s.len)
  return b

proc toStr(b: openArray[byte]): string =
  var s = newString(b.len)
  if b.len > 0:
    copyMem(addr s[0], unsafeAddr b[0], b.len)
  return s

proc readU32(t: StreamTransport): Future[uint32] {.async.} =
  # Frame integers are network byte order (big-endian); see the frame layout below.
  var b: array[4, byte]
  await t.readExactly(addr b[0], 4)
  return
    (uint32(b[0]) shl 24) or (uint32(b[1]) shl 16) or (uint32(b[2]) shl 8) or
    uint32(b[3])

proc writeResponse(t: StreamTransport, ret: int32, body: seq[byte]) {.async.} =
  # Response frame: [i32 ret][u32 len][body], big-endian.
  var hdr = newSeq[byte](8)
  let r = cast[uint32](ret)
  hdr[0] = byte(r shr 24)
  hdr[1] = byte(r shr 16)
  hdr[2] = byte(r shr 8)
  hdr[3] = byte(r and 0xFF)
  let l = uint32(body.len)
  hdr[4] = byte(l shr 24)
  hdr[5] = byte(l shr 16)
  hdr[6] = byte(l shr 8)
  hdr[7] = byte(l and 0xFF)
  discard await t.write(hdr)
  if body.len > 0:
    discard await t.write(body)

proc dispatch(meth: string, payload: seq[byte]): Future[(int32, seq[byte])] {.async.} =
  # The library's own state object — no FFIContext needed, we call the async
  # procs directly. `MyTimer` only carries a name, so building it per request
  # is free and keeps the handler stateless.
  let timer = MyTimer(name: "ipc-server")
  case meth
  of "version":
    let r = await myTimerVersion(timer)
    if r.isOk:
      return (RetOk, cborEncode(r.get())) # string -> CBOR text
    return (RetErr, toBytes(r.error()))
  of "echo":
    let env = cborDecode(payload, EchoReqEnv)
    if env.isErr:
      return (RetErr, toBytes(env.error()))
    let r = await myTimerEcho(timer, env.get().req)
    if r.isOk:
      return (RetOk, cborEncode(r.get()))
    return (RetErr, toBytes(r.error()))
  of "complex":
    let env = cborDecode(payload, ComplexReqEnv)
    if env.isErr:
      return (RetErr, toBytes(env.error()))
    let r = await myTimerComplex(timer, env.get().req)
    if r.isOk:
      return (RetOk, cborEncode(r.get()))
    return (RetErr, toBytes(r.error()))
  of "schedule":
    let env = cborDecode(payload, ScheduleReqEnv)
    if env.isErr:
      return (RetErr, toBytes(env.error()))
    let r =
      await myTimerSchedule(timer, env.get().job, env.get().retry, env.get().schedule)
    if r.isOk:
      return (RetOk, cborEncode(r.get()))
    return (RetErr, toBytes(r.error()))
  else:
    return (RetErr, toBytes("unknown method: " & meth))

proc onConnection(
    server: StreamServer, transp: StreamTransport
) {.async: (raises: []).} =
  try:
    while not transp.atEof():
      let mlen = await readU32(transp)
      var mbytes = newSeq[byte](int(mlen))
      if mlen > 0'u32:
        await transp.readExactly(addr mbytes[0], int(mlen))
      let plen = await readU32(transp)
      var payload = newSeq[byte](int(plen))
      if plen > 0'u32:
        await transp.readExactly(addr payload[0], int(plen))
      let (ret, body) = await dispatch(toStr(mbytes), payload)
      await writeResponse(transp, ret, body)
  except CatchableError:
    discard # peer closed or malformed frame: drop the connection
  try:
    await transp.closeWait()
  except CatchableError:
    discard

proc serveLoop(address: string) {.async.} =
  var server: StreamServer
  if address.startsWith("unix:"):
    let path = address[5 ..^ 1]
    removeFile(path) # clear a stale socket so bind() succeeds
    server = createStreamServer(initTAddress(path), onConnection, {ReuseAddr})
  elif address.startsWith("tcp:"):
    let hp = address[4 ..^ 1]
    let sep = hp.rfind(':')
    doAssert sep > 0, "tcp address must be tcp:<host>:<port>"
    server =
      createStreamServer(
        initTAddress(hp[0 ..< sep], Port(parseInt(hp[sep + 1 ..^ 1]))),
        onConnection,
        {ReuseAddr},
      )
  else:
    raise newException(ValueError, "address must be unix:<path> or tcp:<host>:<port>")
  server.start()
  echo "[serve] listening on ", address
  await server.join()

proc my_timer_serve(address: cstring): cint {.exportc, cdecl, dynlib.} =
  ## C entry point: boot the library runtime and run the socket server forever.
  ## Blocks the calling thread. `address` is "unix:<path>" or "tcp:<host>:<port>".
  initializeLibrary()
  initEventRegistry(serveEventRegistry)
  ffiCurrentEventRegistry = addr serveEventRegistry
  try:
    waitFor serveLoop($address)
  except CatchableError as e:
    echo "[serve] error: ", e.msg
    return 1
  return 0
