## The pool under a host that creates and destroys contexts from many threads,
## which is what a foreign binding does. Each case here stands for one fault that
## only appears when a slot changes owner while other threads are using the pool,
## and that a single-threaded test cannot see.
## Validate with NIM_FFI_SAN=tsan NIM_FFI_MM=orc.

import std/[atomics, monotimes, os, strutils]
from std/times import inMilliseconds, inNanoseconds
import unittest2
import results
import ffi
import ./helpers

type ChurnLib = ref object
  served: int

startWatchdog(180_000, "a create or a recycle never returned")

registerReqFFI(ChurnWork, lib: ptr ChurnLib):
  proc(n: int): Future[Result[int, string]] {.async.} =
    return ok(n)

var churnPool: FFIContextPool[ChurnLib]
  ## Lives for the process, like the pool a library declares. A slot keeps the
  ## buffers it allocated until its context is destroyed, so a pool that goes out
  ## of scope around live slots is what strands them.

suite "a context token is safe for a host to hold":
  test "no token lands in the first page":
    # A host in a garbage-collected language keeps this handle in a pointer, and
    # a collector reads a small integer as a corrupt one.
    for _ in 0 ..< 4:
      let ctx = churnPool.createFFIContext().valueOr:
        check false
        return
      check cast[uint](ctx.ffiToken()) >= 4096'u
      check churnPool.destroyFFIContext(ctx).isOk()

type Churn = object
  pool: ptr FFIContextPool[ChurnLib]
  iters: int
  createFailures: Atomic[int]
  recycleFailures: Atomic[int]
  replyFailures: Atomic[int]
  replyNs: Atomic[int64]
  replies: Atomic[int]

proc churnLoop(c: ptr Churn) =
  for _ in 0 ..< c.iters:
    let ctx = c.pool[].createFFIContext().valueOr:
      c.createFailures.atomicInc()
      return

    let started = getMonoTime()
    let reply = call(ctx, ChurnWork.ffiNewReq(1))
    if reply.ret == RET_OK and reply.retCode == RET_OK:
      discard c.replyNs.fetchAdd((getMonoTime() - started).inNanoseconds)
      c.replies.atomicInc()
    else:
      c.replyFailures.atomicInc()

    c.pool[].recycleFFIContext(ctx).isOkOr:
      c.recycleFailures.atomicInc()
      echo "recycle failed: ", error # the reason matters more than the count

proc churnBody(c: ptr Churn) {.thread.} =
  {.cast(gcsafe).}:
    churnLoop(c)

suite "many threads share the pool":
  test "a slot changing owner fails no create, no recycle and no reply":
    # A freed slot must be taken by another thread at once, which is when a
    # handover goes wrong. Eight keeps every slot moving on the two cores a CI
    # runner has; FFI_CHURN_WORKERS raises it, and the faults this guards were
    # measured at sixteen.
    let workers = parseInt(getEnv("FFI_CHURN_WORKERS", "8"))
    let pool = addr churnPool
    defer:
      discard pool[].shutdownFFIContextPool()

    # Initialise every slot from this thread first. A slot's per-context state
    # is allocated by whoever creates the first context in it, and a worker
    # thread takes its allocator with it when it exits: left to the workers, the
    # pool would hold memory no thread can free afterwards. Once a slot is
    # initialised the workers only reuse it, which allocates nothing.
    var warm: seq[ptr FFIContext[ChurnLib]] = @[]
    for _ in 0 ..< MaxFFIContexts:
      let ctx = pool[].createFFIContext().valueOr:
        check false
        break
      warm.add(ctx)
    for ctx in warm:
      check pool[].recycleFFIContext(ctx).isOk()

    var c = Churn(pool: pool, iters: parseInt(getEnv("FFI_CHURN_ITERS", "30")))
    var threads = newSeq[Thread[ptr Churn]](workers)
    for i in 0 ..< workers:
      createThread(threads[i], churnBody, addr c)
    for i in 0 ..< workers:
      joinThread(threads[i])

    # A create that fails means a slot was lost; a recycle that fails means the
    # owner was told its teardown did not complete when it had.
    check c.createFailures.load() == 0
    check c.recycleFailures.load() == 0
    # A request of the new owner answered as the old owner's, or never answered.
    check c.replyFailures.load() == 0
    check c.replies.load() == workers * c.iters

    # A reply must not wait for the FFI thread's fallback timeout: a reused slot
    # is woken by the submit that made it active again.
    let avgMs = float(c.replyNs.load() div max(c.replies.load(), 1)) / 1e6
    echo "churn: replies=", c.replies.load(), " avg reply=", avgMs, "ms"
    check avgMs < 20.0
