## Exercises the CBOR-free scalar fast path (`{.ffi: "abi = c".}` on an
## all-scalar signature). A scalar proc's C export takes its scalar args
## directly (no `reqCbor`/`reqCborLen`), packs them inline into the request,
## and the response rides back as raw bytes — no CBOR envelope either way.
##
## Two angles are covered: the C-export shape (ctx, callback, userData, args…)
## driven through a real FFI thread, and the Nim-native shape (the user proc
## name still resolves to its declared `Future[Result[T, string]]`).

import std/[locks, strutils, sequtils]
import unittest2
import results
import ffi
import ffi/codegen/meta
import ffi/internal/ffi_scalar

type ScalarLib = object
  base: int

# Stub the dylib NimMain importc that declareLibrary emits (this links as an exe).
{.emit: "void libscalarfastNimMain(void) {}".}

declareLibrary("scalarfast", ScalarLib)

type ScalarConfig {.ffi.} = object
  base: int

proc scalarfast_create*(
    cfg: ScalarConfig
): Future[Result[ScalarLib, string]] {.ffiCtor.} =
  return ok(ScalarLib(base: cfg.base))

proc scalarfast_add*(
    lib: ScalarLib, a: int, b: int
): Future[Result[int, string]] {.ffi: "abi = c".} =
  ## Two scalar params, scalar return — the flagship fast-path shape.
  return ok(lib.base + a + b)

proc scalarfast_version*(
    lib: ScalarLib
): Future[Result[string, string]] {.ffi: "abi = c".} =
  ## No params, string return (rides back as raw UTF-8, no CBOR).
  return ok("scalarfast v1")

proc scalarfast_scale*(
    lib: ScalarLib, factor: float
): Future[Result[float, string]] {.ffi: "abi = c".} =
  ## Float round-trip through the uint64 slot.
  return ok(factor * 2.0)

proc scalarfast_positive*(
    lib: ScalarLib, n: int
): Future[Result[bool, string]] {.ffi: "abi = c".} =
  return ok(n > 0)

proc scalarfast_checked*(
    lib: ScalarLib, n: int
): Future[Result[int, string]] {.ffi: "abi = c".} =
  ## Error path — a scalar proc that can fail surfaces Result.err.
  if n < 0:
    return err("negative not allowed")
  return ok(n * 2)

proc scalarfast_blank*(
    lib: ScalarLib
): Future[Result[string, string]] {.ffi: "abi = c".} =
  ## Empty-string return — must ride back as a genuine 0-length RET_OK payload,
  ## not the CBOR-null sentinel.
  return ok("")

## C-shape callback harness (mirrors test_ffi_context.nim).

type CallbackData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  msg: array[1024, byte]
  msgLen: int

proc initCallbackData(d: var CallbackData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitCallbackData(d: var CallbackData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

proc testCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].retCode = retCode
  let n = min(int(len), d[].msg.len)
  if n > 0 and not msg.isNil:
    copyMem(addr d[].msg[0], msg, n)
  d[].msgLen = n
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc waitCallback(d: var CallbackData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc scalarU64(d: CallbackData): uint64 =
  ## Reads the 8-byte native-endian POD image the fast path returns.
  doAssert d.msgLen == sizeof(uint64), "expected 8 scalar bytes, got " & $d.msgLen
  var u: uint64
  copyMem(addr u, unsafeAddr d.msg[0], sizeof(uint64))
  u

proc scalarInt(d: CallbackData): int =
  int(cast[int64](scalarU64(d)))

proc scalarFloat(d: CallbackData): float =
  cast[float64](scalarU64(d))

proc scalarBool(d: CallbackData): bool =
  scalarU64(d) != 0'u64

proc scalarStr(d: CallbackData): string =
  var s = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr s[0], unsafeAddr d.msg[0], d.msgLen)
  s

proc callbackErr(d: CallbackData): string =
  scalarStr(d)

proc encodedPtr(bytes: var seq[byte]): ptr byte =
  if bytes.len == 0:
    nil
  else:
    cast[ptr byte](addr bytes[0])

proc callbackBytesOf(d: CallbackData): seq[byte] =
  var bytes = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr bytes[0], unsafeAddr d.msg[0], d.msgLen)
  bytes

proc makeCtx(base: int): ptr FFIContext[ScalarLib] =
  var d: CallbackData
  initCallbackData(d)
  defer:
    deinitCallbackData(d)
  var cfg = cborEncode(ScalarfastCreateCtorReq(cfg: ScalarConfig(base: base)))
  let ret = scalarfast_create(encodedPtr(cfg), cfg.len.csize_t, testCallback, addr d)
  doAssert not ret.isNil()
  waitCallback(d)
  doAssert d.retCode == RET_OK
  let addrStr = cborDecode(callbackBytesOf(d), string).value
  cast[ptr FFIContext[ScalarLib]](cast[uint](parseBiggestUInt(addrStr)))

suite "scalar fast path — C export shape":
  test "two int params + int return, threads through the base state":
    let ctx = makeCtx(100)
    defer:
      check ScalarLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    check scalarfast_add(ctx, testCallback, addr d, 20, 3) == RET_OK
    waitCallback(d)
    check d.retCode == RET_OK
    check scalarInt(d) == 123

  test "no params, string return rides back as raw UTF-8":
    let ctx = makeCtx(0)
    defer:
      check ScalarLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    check scalarfast_version(ctx, testCallback, addr d) == RET_OK
    waitCallback(d)
    check d.retCode == RET_OK
    check scalarStr(d) == "scalarfast v1"

  test "empty string return rides back as a real 0-length RET_OK payload":
    let ctx = makeCtx(0)
    defer:
      check ScalarLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    check scalarfast_blank(ctx, testCallback, addr d) == RET_OK
    waitCallback(d)
    check d.retCode == RET_OK
    check d.msgLen == 0 # NOT 1 (would be the 0xf6 sentinel)
    check scalarStr(d) == ""

  test "float param round-trips through the uint64 slot":
    let ctx = makeCtx(0)
    defer:
      check ScalarLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    check scalarfast_scale(ctx, testCallback, addr d, 2.5) == RET_OK
    waitCallback(d)
    check d.retCode == RET_OK
    check scalarFloat(d) == 5.0

  test "bool return":
    let ctx = makeCtx(0)
    defer:
      check ScalarLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    check scalarfast_positive(ctx, testCallback, addr d, -4) == RET_OK
    waitCallback(d)
    check d.retCode == RET_OK
    check scalarBool(d) == false

  test "error result surfaces as RET_ERR with a raw UTF-8 message":
    let ctx = makeCtx(0)
    defer:
      check ScalarLibFFIPool.destroyFFIContext(ctx).isOk()

    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)

    check scalarfast_checked(ctx, testCallback, addr d, -1) == RET_OK
    waitCallback(d)
    check d.retCode == RET_ERR
    check callbackErr(d) == "negative not allowed"

  test "invalid ctx is rejected before enqueue":
    var d: CallbackData
    initCallbackData(d)
    defer:
      deinitCallbackData(d)
    let bogus = cast[ptr FFIContext[ScalarLib]](nil)
    check scalarfast_add(bogus, testCallback, addr d, 1, 2) == RET_ERR

suite "scalar fast path — Nim-native shape":
  test "user proc name keeps its Future[Result[T, string]] signature":
    let add = waitFor scalarfast_add(ScalarLib(base: 1), 2, 3)
    check add.isOk()
    check add.value == 6

    let ver = waitFor scalarfast_version(ScalarLib(base: 0))
    check ver.isOk()
    check ver.value == "scalarfast v1"

    let bad = waitFor scalarfast_checked(ScalarLib(base: 0), -5)
    check bad.isErr()
    check bad.error == "negative not allowed"

    let blank = waitFor scalarfast_blank(ScalarLib(base: 0))
    check blank.isOk()
    check blank.value == ""

# `ffiProcRegistry` is a compile-time var, so its assertions run in a static
# block (mirrors test_abi_format.nim). A scalar-only `abi = c` proc must be
# flagged, recognised by `isScalarOnly`, and dropped from `bindableProcs`.
static:
  const scalarNames = [
    "scalarfast_add", "scalarfast_version", "scalarfast_scale", "scalarfast_positive",
    "scalarfast_checked", "scalarfast_blank",
  ]
  var seen = 0
  for p in ffiProcRegistry:
    if p.procName in scalarNames:
      doAssert p.scalarFastPath, p.procName & " should be scalarFastPath"
      doAssert p.abiFormat == ABIFormat.C
      doAssert isScalarOnly(p), p.procName & " should be isScalarOnly"
      inc seen
  doAssert seen == scalarNames.len, "saw " & $seen & " scalar procs"
  # The ctor stays on the CBOR path and remains bindable.
  doAssert bindableProcs(ffiProcRegistry).anyIt(it.procName == "scalarfast_create")
  doAssert not bindableProcs(ffiProcRegistry).anyIt(it.scalarFastPath)
