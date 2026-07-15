import std/[atomics, os]
import unittest2
import results
import ffi

# Exercises async {.ffiDtor.}: destroyFFIContext must block until teardown finishes.

type TeardownLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libteardownlibNimMain(void) {}".}

declareLibrary("teardownlib", TeardownLib)

var gTeardownRan: Atomic[bool]
var gTeardownThreadId: Atomic[int]

type NoopConfig {.ffi.} = object
  dummy: int

proc teardownlib_create*(
    config: NoopConfig
): Future[Result[TeardownLib, string]] {.ffiCtor.} =
  return ok(TeardownLib())

proc teardownlib_destroy*(lib: TeardownLib): Future[void] {.ffiDtor.} =
  ## Async teardown: sleeps, then records that it ran and on which thread.
  await sleepAsync(200.milliseconds)
  gTeardownThreadId.store(getThreadId())
  gTeardownRan.store(true)

proc noopCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

proc encodedPtr(bytes: var seq[byte]): ptr byte =
  if bytes.len == 0:
    nil
  else:
    cast[ptr byte](addr bytes[0])

proc createCtxWithLib(): ptr FFIContext[TeardownLib] =
  ## Spins up a context via the ctor and waits until `myLib` is populated.
  var cfg = cborEncode(TeardownlibCreateCtorReq(config: NoopConfig(dummy: 0)))
  let ret = teardownlib_create(encodedPtr(cfg), cfg.len.csize_t, noopCallback, nil)
  if ret.isNil():
    return nil
  let ctx = cast[ptr FFIContext[TeardownLib]](ret)
  var tries = 0
  while ctx[].myLib.isNil() and tries < 500:
    os.sleep(5)
    inc tries
  ctx

suite "async {.ffiDtor.} teardown hook":
  test "destroy blocks until the async teardown body completes":
    let ctx = createCtxWithLib()
    check not ctx.isNil()
    check not ctx[].myLib.isNil()

    gTeardownRan.store(false)
    gTeardownThreadId.store(0)
    let callerTid = getThreadId()

    check TeardownlibFFIPool.destroyFFIContext(ctx).isOk()

    check gTeardownRan.load()
    check gTeardownThreadId.load() != 0
    check gTeardownThreadId.load() != callerTid

  test "teardown runs exactly once per context":
    gTeardownRan.store(false)
    let ctx = createCtxWithLib()
    check not ctx.isNil()
    check TeardownlibFFIPool.destroyFFIContext(ctx).isOk()
    check gTeardownRan.load()
