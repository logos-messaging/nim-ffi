## Shutdown stops what destroy deliberately keeps: a recycled slot hands its
## worker and event threads to the next owner, so only an explicit shutdown
## takes them down before the host exits.

import std/[strutils]
import unittest2
import results
import ffi
import ./helpers

type ShutdownLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libshutdownlibNimMain(void) {}".}

declareLibrary("shutdownlib", ShutdownLib)

proc shutdownlib_ping*(lib: ShutdownLib): Future[Result[int, string]] {.ffi.} =
  return ok(1)

proc liveThreads(): int =
  ## Linux-only: the OS thread count is the property under test, and /proc is
  ## the only portable-enough way to read it.
  when defined(linux):
    for line in readFile("/proc/self/status").splitLines():
      if line.startsWith("Threads:"):
        return parseInt(line.split()[1])
    -1
  else:
    -1

suite "pool shutdown":
  test "recycled slots keep their threads until shutdown joins them":
    # Baseline after a full cycle: the runtime brings up threads of its own on
    # first use (a sanitizer's background thread), and those never go away.
    let warmup = ShutdownLibFFIPool.createFFIContext().get()
    check ShutdownLibFFIPool.recycleFFIContext(warmup).isOk()
    waitSlotFree(warmup)
    check shutdownlib_shutdown() == 0
    let baseline = liveThreads()

    let first = ShutdownLibFFIPool.createFFIContext().get()
    let firstToken = first.ffiToken()
    check ShutdownLibFFIPool.recycleFFIContext(first).isOk()
    waitSlotFree(first)

    # The slot is free, but destroy left its threads running for the next owner.
    when defined(linux):
      check liveThreads() > baseline

    let second = ShutdownLibFFIPool.createFFIContext().get()
    let secondToken = second.ffiToken()

    check shutdownlib_shutdown() == 0

    check not ShutdownLibFFIPool.isValidCtx(firstToken)
    check not ShutdownLibFFIPool.isValidCtx(secondToken)
    check ShutdownLibFFIPool.quarantinedSlots() == 0
    when defined(linux):
      check liveThreads() == baseline

  test "the pool still serves after a shutdown":
    let ctx = ShutdownLibFFIPool.createFFIContext().get()
    check ShutdownLibFFIPool.isValidCtx(ctx.ffiToken())
    check shutdownlib_shutdown() == 0

  test "shutdown on an idle pool is a no-op":
    check shutdownlib_shutdown() == 0
