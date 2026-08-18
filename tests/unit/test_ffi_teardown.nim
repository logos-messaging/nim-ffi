import std/[atomics, os]
import unittest2
import results
import ffi

# Exercises async {.ffiDtor.} on the destroy and the recycle path.
# test_ffi_teardown.nim.cfg cuts TeardownTimeout to 1s for every suite here.

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
  ## Records that it ran and on which thread. `gTeardownHangs` makes it sleep
  ## past every timeout in play, well clear of any sanitizer slowdown.
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

proc waitSlotFree[T](ctx: ptr FFIContext[T]) =
  ## `requestRecycle` returns once the recycle fired its done signal, which is
  ## one step before the FFI thread releases the claim (the fire has to come
  ## first, or a thread claiming the slot would take it as its own answer). Wait
  ## that step out before a check that depends on the slot being free.
  let deadline = Moment.now() + 5.seconds
  while ctx.isInUse() and Moment.now() < deadline:
    os.sleep(1)

proc createCtxWithLib(): ptr FFIContext[TeardownLib] =
  ## Spins up a context and waits on `libReady`, the flag the teardown gates on.
  # Not `myLib`: the worker points that at its fallback before the ctor runs.
  var cfg = cborEncode(TeardownlibCreateCtorReq(config: NoopConfig(dummy: 0)))
  let ret = teardownlib_create(encodedPtr(cfg), cfg.len.csize_t, noopCallback, nil)
  if ret.isNil():
    return nil
  let ctx = TeardownLibFFIPool.resolveCtx(ret)
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
  # Recycle is the path the generated C destroy wrapper takes.
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
    check teardownlib_destroy(ctx.ffiToken()) == RET_OK
    check gTeardownRan.load()

  test "a slot reused after teardown tears down again":
    let first = createCtxWithLib()
    check not first.isNil()
    check TeardownlibFFIPool.recycleFFIContext(first).isOk()
    waitSlotFree(first)

    gTeardownRan.store(false)
    let second = createCtxWithLib()
    check not second.isNil()
    # Lowest free slot wins, so a fresh slot here would prove nothing.
    check second == first
    check not second[].myLib.isNil()
    check TeardownlibFFIPool.recycleFFIContext(second).isOk()
    check gTeardownRan.load()

  test "a teardown past TeardownTimeout quarantines the slot":
    # Runs last in this file: the slot never comes back.
    let ctx = createCtxWithLib()
    check not ctx.isNil()

    gTeardownRan.store(false)
    gTeardownHangs.store(true)
    let t0 = Moment.now()
    let res = TeardownlibFFIPool.recycleFFIContext(ctx)
    let elapsed = Moment.now() - t0
    gTeardownHangs.store(false)

    # The timeout ended the wait, not an early bail or the body finishing.
    check elapsed >= TeardownTimeout
    check elapsed < RecycleWaitTimeout
    check not gTeardownRan.load()
    # A body that never finished cannot promise the thread is free of it, so the
    # recycle fails and the library is kept. See test_ffi_dtor_orphan_reuse.
    check res.isErr()
    check not ctx[].myLib.isNil()
    check TeardownlibFFIPool.quarantinedSlots() == 1

    let next = createCtxWithLib()
    check not next.isNil()
    check next != ctx
    check not next[].myLib.isNil()
    check TeardownlibFFIPool.recycleFFIContext(next).isOk()
    check gTeardownRan.load()
