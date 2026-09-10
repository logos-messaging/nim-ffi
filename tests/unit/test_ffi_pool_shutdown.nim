## Where a slot's threads go: a recycle hands them on, the last one parks them, shutdown ends them.

import std/[os, strutils]
import unittest2
import results
import ffi

type ShutdownLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libshutdownlibNimMain(void) {}".}

declareLibrary("shutdownlib", ShutdownLib)

proc shutdownlib_ping*(lib: ShutdownLib): Future[Result[int, string]] {.ffi.} =
  return ok(1)

proc liveThreads(): int =
  ## Linux-only: /proc is the only portable-enough way to read the OS thread count.
  when defined(linux):
    for line in readFile("/proc/self/status").splitLines():
      if line.startsWith("Threads:"):
        return parseInt(line.split()[1])
    -1
  else:
    -1

proc openFds(): int =
  when defined(linux):
    var count = 0
    for _ in walkDir("/proc/self/fd"):
      count.inc()
    count
  else:
    -1

template baselineThreads(): int =
  ## Measured after a full cycle: a sanitizer starts threads of its own that never go away.
  block:
    let warmup = ShutdownLibFFIPool.createFFIContext().get()
    check ShutdownLibFFIPool.recycleFFIContext(warmup).isOk()
    check shutdownlib_shutdown() == 0
    liveThreads()

suite "pool shutdown":
  test "recycling the last context reaps its threads":
    let baseline = baselineThreads()

    let ctx = ShutdownLibFFIPool.createFFIContext().get()
    let token = ctx.ffiToken()
    when defined(linux):
      check liveThreads() > baseline

    check ShutdownLibFFIPool.recycleFFIContext(ctx).isOk()

    check not ShutdownLibFFIPool.isValidCtx(token)
    when defined(linux):
      check liveThreads() == baseline

  test "a recycled slot keeps its threads while another context is live":
    let baseline = baselineThreads()

    let first = ShutdownLibFFIPool.createFFIContext().get()
    let second = ShutdownLibFFIPool.createFFIContext().get()
    check ShutdownLibFFIPool.recycleFFIContext(second).isOk()

    # `first` still owns a slot, so the pool holds the reap for the next owner.
    when defined(linux):
      check liveThreads() > baseline

    check ShutdownLibFFIPool.recycleFFIContext(first).isOk()
    when defined(linux):
      check liveThreads() == baseline

  test "a create/recycle cycle churns no fd":
    # The reap stops the threads, but the signals stay open: under refc a close is not an option.
    let warmup = ShutdownLibFFIPool.createFFIContext().get()
    check ShutdownLibFFIPool.recycleFFIContext(warmup).isOk()
    let baseline = openFds()

    for _ in 0 ..< 50:
      let ctx = ShutdownLibFFIPool.createFFIContext().get()
      check ShutdownLibFFIPool.recycleFFIContext(ctx).isOk()

    when defined(linux):
      check openFds() == baseline

  test "shutdown stops a context the host never destroyed":
    let baseline = baselineThreads()
    let quarantined = ShutdownLibFFIPool.quarantinedSlots()

    let ctx = ShutdownLibFFIPool.createFFIContext().get()

    check shutdownlib_shutdown() == 0

    # The library was never torn down, so the slot must not serve a next owner.
    check ShutdownLibFFIPool.quarantinedSlots() == quarantined + 1
    when defined(linux):
      check liveThreads() == baseline

  test "shutdown stops the {.ffiStatic.} context, and a static call rebuilds it":
    let baseline = baselineThreads()
    let quarantined = ShutdownLibFFIPool.quarantinedSlots()

    # What a `{.ffiStatic.}` entry point calls: the shared context holds its slot until a shutdown.
    check ShutdownLibFFIPool.staticFFIContext().isOk()
    when defined(linux):
      check liveThreads() > baseline

    check shutdownlib_shutdown() == 0

    # It owns no library, so its slot comes back rather than being quarantined.
    check ShutdownLibFFIPool.quarantinedSlots() == quarantined
    when defined(linux):
      check liveThreads() == baseline

    check ShutdownLibFFIPool.staticFFIContext().isOk()
    when defined(linux):
      check liveThreads() > baseline
    check shutdownlib_shutdown() == 0
    when defined(linux):
      check liveThreads() == baseline

  test "the pool still serves after a shutdown":
    let ctx = ShutdownLibFFIPool.createFFIContext().get()
    check ShutdownLibFFIPool.isValidCtx(ctx.ffiToken())
    check shutdownlib_shutdown() == 0

  test "shutdown on an idle pool is a no-op":
    check shutdownlib_shutdown() == 0
