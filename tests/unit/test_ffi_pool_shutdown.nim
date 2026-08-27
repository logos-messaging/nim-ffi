## Where the worker and event threads of a slot go: a recycle hands them to the next owner, recycling the last live context parks them, and shutdown takes down what a host still holds.

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
  ## Linux-only: the OS thread count is the property under test, and /proc is the only portable-enough way to read it.
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
  ## After a full cycle: the runtime brings up threads of its own on first use (a sanitizer's background thread), and those never go away. A template so a failed step fails the test that asked, instead of killing the suite.
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
    # The reap stops the threads, but the signals stay open for the next owner: under refc closing them is not an option.
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

  test "the pool still serves after a shutdown":
    let ctx = ShutdownLibFFIPool.createFFIContext().get()
    check ShutdownLibFFIPool.isValidCtx(ctx.ffiToken())
    check shutdownlib_shutdown() == 0

  test "shutdown on an idle pool is a no-op":
    check shutdownlib_shutdown() == 0
