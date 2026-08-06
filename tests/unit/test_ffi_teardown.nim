import std/[atomics, os]
import unittest2
import results
import ffi

# Exercises async {.ffiDtor.}: both the destroy path and the recycle path must
# block until teardown finishes. test_ffi_teardown.nim.cfg shortens
# TeardownTimeout for every suite here, so read timings against 1s, not 10s.

type TeardownLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libteardownlibNimMain(void) {}".}

declareLibrary("teardownlib", TeardownLib)

var gTeardownRan: Atomic[bool]
var gTeardownThreadId: Atomic[int]
var gTeardownHangs: Atomic[bool]

type NoopConfig {.ffi.} = object
  dummy: int

proc teardownlib_create*(
    config: NoopConfig
): Future[Result[TeardownLib, string]] {.ffiCtor.} =
  return ok(TeardownLib())

proc teardownlib_destroy*(lib: TeardownLib): Future[void] {.ffiDtor.} =
  ## Async teardown: sleeps, then records that it ran and on which thread. While
  ## `gTeardownHangs` is set it sleeps far past every timeout in play, so no
  ## sanitizer slowdown can make a natural finish look like a cancelled one.
  if gTeardownHangs.load():
    await sleepAsync(TeardownTimeout + 60.seconds)
  else:
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
  ## Spins up a context via the ctor and waits until the library is ready.
  # Waits on `libReady`, not `myLib`: the ctor sets the flag after the pointer,
  # and `libReady` is what gates the teardown hook.
  var cfg = cborEncode(TeardownlibCreateCtorReq(config: NoopConfig(dummy: 0)))
  let ret = teardownlib_create(encodedPtr(cfg), cfg.len.csize_t, noopCallback, nil)
  if ret.isNil():
    return nil
  let ctx = cast[ptr FFIContext[TeardownLib]](ret)
  var tries = 0
  while not ctx[].libReady.load() and tries < 500:
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

suite "{.ffiDtor.} teardown on the recycle path":
  # Recycle is the path the generated C destroy wrapper takes, so a dtor body
  # that only ran on destroy would never run in a real host.
  test "recycle blocks until the async teardown body completes":
    let ctx = createCtxWithLib()
    check not ctx.isNil()
    check not ctx[].myLib.isNil()

    gTeardownRan.store(false)
    gTeardownThreadId.store(0)
    let callerTid = getThreadId()

    check TeardownlibFFIPool.recycleFFIContext(ctx).isOk()

    check gTeardownRan.load()
    check gTeardownThreadId.load() != 0
    check gTeardownThreadId.load() != callerTid

  test "the C-exported destroy wrapper runs the teardown":
    let ctx = createCtxWithLib()
    check not ctx.isNil()

    gTeardownRan.store(false)
    check teardownlib_destroy(cast[pointer](ctx)) == RET_OK
    check gTeardownRan.load()

  test "a slot reused after teardown tears down again":
    let first = createCtxWithLib()
    check not first.isNil()
    check TeardownlibFFIPool.recycleFFIContext(first).isOk()

    gTeardownRan.store(false)
    let second = createCtxWithLib()
    check not second.isNil()
    # createFFIContext claims the lowest free slot, so a released slot comes
    # back. Without this the test would pass on a fresh slot and prove nothing.
    check second == first
    check not second[].myLib.isNil()
    check TeardownlibFFIPool.recycleFFIContext(second).isOk()
    check gTeardownRan.load()

  test "a teardown past TeardownTimeout still releases the slot":
    let ctx = createCtxWithLib()
    check not ctx.isNil()

    gTeardownRan.store(false)
    gTeardownHangs.store(true)
    let t0 = Moment.now()
    check TeardownlibFFIPool.recycleFFIContext(ctx).isOk()
    let elapsed = Moment.now() - t0
    gTeardownHangs.store(false)

    # The timeout is what ended the wait, not an early bail: the hook outlasts
    # TeardownTimeout, and its tail never ran because cancellation took it.
    check elapsed >= TeardownTimeout
    # The body sleeps a further minute, so returning inside the caller's own
    # ceiling proves the timeout ended the wait, not the body finishing. Bounding
    # by RecycleWaitTimeout keeps the isOk() check above the first to fail.
    check elapsed < RecycleWaitTimeout
    check not gTeardownRan.load()

    # The slot is usable again, and the next owner tears down normally.
    let next = createCtxWithLib()
    check not next.isNil()
    check next == ctx
    check not next[].myLib.isNil()
    check TeardownlibFFIPool.recycleFFIContext(next).isOk()
    check gTeardownRan.load()
