import std/[atomics, os]
import unittest2
import results
import ffi

# Exercises the async `{.ffiDtor.}` teardown hook: a non-empty dtor body is
# lifted into an `ffiTeardown` overload the FFI thread awaits on its own event
# loop right before it exits. `destroyFFIContext` must block until that
# teardown finishes.

type TeardownLib = object

# declareLibrary emits an importc `lib<name>NimMain`; this test links as a plain
# exe, so stub it (mirrors test_ffi_context.nim).
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
  ## Async teardown: sleeps on the FFI event loop, then records that it ran and
  ## on which thread. If destroy didn't wait, `gTeardownRan` would still be false
  ## when the test checks it.
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
  ## Spins up a context via the ctor and waits until `myLib` is populated (set on
  ## the FFI thread when the ctor request is dispatched), so teardown has a lib.
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

    # If destroy returned before awaiting the teardown, this would be false.
    check gTeardownRan.load()
    # And it must have run on the FFI thread, not the caller's.
    check gTeardownThreadId.load() != 0
    check gTeardownThreadId.load() != callerTid

  test "teardown runs exactly once per context":
    gTeardownRan.store(false)
    let ctx = createCtxWithLib()
    check not ctx.isNil()
    check TeardownlibFFIPool.destroyFFIContext(ctx).isOk()
    check gTeardownRan.load()
