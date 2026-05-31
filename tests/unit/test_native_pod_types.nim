## Type coverage for the *native* (POD) ABI specifically: one `{.ffi.}` "kitchen
## sink" object whose fields span every supported field shape — all integer
## widths, both floats, bool, string, sequences (of scalars, strings, floats and
## nested structs), Option/Maybe, and a nested struct by value — is sent in as a
## C-POD struct and returned as a typed C-POD struct, then compared to the value
## the Nim-native API produces.
##
## The CBOR side of this matrix already lives in `test_serial.nim` (the codec)
## and `test_wire_compat.nim` (the bytes); this file pins the parallel guarantee
## for the zero-serialization path: `nimToPod` -> `*NativeExport` ->
## `clonePod`/`podToNim` of the typed return carry every type back unchanged.
##
## Compiling the file also proves the native-POD codegen *accepts* every type
## (an unsupported field would fail the macro expansion). Runs under orc + refc.

import std/[options, locks]
import unittest2
import results
import ffi

type Maybe[T] = Option[T]

type CovLib = object

type CovConfig {.ffi.} = object
  label: string

type Inner {.ffi.} = object
  tag: string
  weight: float64
  flag: bool

type AllTypes {.ffi.} = object
  b: bool
  i: int
  i8: int8
  i16: int16
  i32: int32
  i64: int64
  u: uint
  u8: uint8
  u16: uint16
  u32: uint32
  u64: uint64
  f32: float32
  f64: float64
  s: string
  ints: seq[int]
  strs: seq[string]
  floats: seq[float64]
  inners: seq[Inner]
  optI: Option[int]
  optS: Option[string]
  maybeB: Maybe[bool]
  inner: Inner

proc cov_create(cfg: CovConfig): Future[Result[CovLib, string]] {.ffiCtor.} =
  discard cfg
  return ok(CovLib())

proc cov_echo(
    lib: CovLib, req: AllTypes
): Future[Result[AllTypes, string]] {.ffi.} =
  ## Round-trips the whole graph straight back.
  discard lib
  return ok(req)

proc cov_destroy(lib: CovLib) {.ffiDtor.} =
  discard

# A fully-populated sample (distinct, non-default values everywhere).
proc sample(): AllTypes =
  AllTypes(
    b: true,
    i: -123456,
    i8: -8,
    i16: -1600,
    i32: -320000,
    i64: -6400000000'i64,
    u: 123456'u,
    u8: 200'u8,
    u16: 60000'u16,
    u32: 4000000000'u32,
    u64: 18000000000000000000'u64,
    f32: 3.5'f32,
    f64: 2.718281828459045,
    s: "héllo, FFI",
    ints: @[1, -2, 3, -4],
    strs: @["a", "", "ccc"],
    floats: @[1.5, -2.25, 3.125],
    inners:
      @[Inner(tag: "x", weight: 1.0, flag: false), Inner(tag: "y", weight: -9.5, flag: true)],
    optI: some(42),
    optS: none(string),
    maybeB: some(true),
    inner: Inner(tag: "nested", weight: 0.0, flag: true),
  )

# --- blocking callback capture ----------------------------------------------
type Cap = object
  lock: Lock
  cond: Cond
  done: bool
  ret: cint
  pod: AllTypesPod # native typed return, deep-copied (c_malloc) in the callback
  hasPod: bool

proc initCap(c: var Cap) =
  c.lock.initLock()
  c.cond.initCond()
  c.done = false
  c.hasPod = false

proc deinitCap(c: var Cap) =
  c.cond.deinitCond()
  c.lock.deinitLock()

proc reset(c: var Cap) =
  acquire(c.lock)
  c.done = false
  c.hasPod = false
  release(c.lock)

proc waitCap(c: var Cap) =
  acquire(c.lock)
  while not c.done:
    wait(c.cond, c.lock)
  release(c.lock)

proc ackCb(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  let c = cast[ptr Cap](ud)
  acquire(c[].lock)
  c[].ret = ret
  c[].done = true
  signal(c[].cond)
  release(c[].lock)

proc nativeCb(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Native ABI: `msg` is a `ptr AllTypesPod`. Deep-copy it (c_malloc, no GC) so
  ## it outlives this callback; the test thread rebuilds the Nim value from it.
  let c = cast[ptr Cap](ud)
  acquire(c[].lock)
  c[].ret = ret
  if ret == RET_OK and not msg.isNil:
    c[].pod = clonePod(cast[ptr AllTypesPod](msg)[])
    c[].hasPod = true
  c[].done = true
  signal(c[].cond)
  release(c[].lock)

suite "native POD ABI — every field type":
  let want = sample()

  test "Nim-native API is the reference round-trip":
    let res = waitFor cov_echo(CovLib(), want)
    check res.isOk
    check res.value == want

  test "native POD ABI carries every type in and back out":
    var cap: Cap
    initCap(cap)
    defer:
      deinitCap(cap)

    # Context via the native ctor (returns the ctx pointer; wait for the body).
    var cfgPod = nimToPod(CovConfig(label: "cov"))
    let ctx = cov_createNativeCtorExport(cfgPod, ackCb, addr cap)
    freePod(cfgPod)
    check not ctx.isNil
    waitCap(cap)

    # Send the whole graph as a C-POD; get a typed C-POD back.
    reset(cap)
    var argPod = nimToPod(want)
    let rc = cov_echoNativeExport(
      cast[ptr FFIContext[CovLib]](ctx), nativeCb, addr cap, argPod
    )
    freePod(argPod) # the export already deep-copied it on the caller thread
    check rc == RET_OK
    waitCap(cap)
    check cap.ret == RET_OK
    check cap.hasPod

    let got = podToNim(cap.pod)
    freePod(cap.pod)
    check got == want # all 22 fields survived the POD round-trip

    check CovLibFFIPool.destroyFFIContext(cast[ptr FFIContext[CovLib]](ctx)).isOk()
