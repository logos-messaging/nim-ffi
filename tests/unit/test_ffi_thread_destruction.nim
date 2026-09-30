## A library's thread-destruction hook runs after the thread body returns, and
## can still drive the thread's dispatcher: nim-brokers stops its dispatch loop
## that way. Reaping the last context must not close the dispatcher under it.

import std/atomics
import unittest2
import results
import ffi
import ./helpers

type HookLib = object

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libhooklibNimMain(void) {}".}

declareLibrary("hooklib", HookLib)

const
  HookNotRun = 0
  HookPolled = 1
  HookRaised = 2

var
  gHookOutcome: Atomic[int]
  gHookError: array[256, char] # a Defect's message, copied out of the dying thread
  gHookArmed {.threadvar.}: bool

startWatchdog(60_000, "reaping the last context never returned")

proc recordError(msg: string) {.gcsafe, raises: [].} =
  let n = min(msg.len, gHookError.len - 1)
  for i in 0 ..< n:
    gHookError[i] = msg[i]
  gHookError[n] = '\0'

proc pollOnThreadExit() {.gcsafe, raises: [].} =
  ## Stands in for nim-brokers' `teardownBrokerThread`.
  try:
    waitFor sleepAsync(1.milliseconds)
    gHookOutcome.store(HookPolled)
  except CatchableError as e:
    recordError(e.msg)
    gHookOutcome.store(HookRaised)
  except Defect as e:
    recordError(e.msg)
    gHookOutcome.store(HookRaised)

proc hooklib_arm*(lib: HookLib): Future[Result[int, string]] {.ffi.} =
  ## Registers the hook on the FFI thread, as a library does on its first use.
  if not gHookArmed:
    gHookArmed = true
    onThreadDestruction(pollOnThreadExit)
  return ok(1)

suite "thread destruction":
  test "a hook registered on the FFI thread can still poll its dispatcher":
    gHookOutcome.store(HookNotRun)
    let ctx = HookLibFFIPool.createFFIContext().get()

    setupCallbackData(armed)
    var rb = cborEncode(HooklibArmReq())
    check hooklib_arm(
      ctx.ffiToken(), testCallback, addr armed, encodedPtr(rb), rb.len.csize_t
    ) == RET_OK
    waitCallback(armed)
    check armed.retCode == RET_OK

    # The last live context: recycling it joins its threads, which runs the hook.
    check HookLibFFIPool.recycleFFIContext(ctx).isOk()

    let outcome = gHookOutcome.load()
    if outcome != HookPolled:
      checkpoint "hook outcome " & $outcome & ": " & $cast[cstring](addr gHookError[0])
    check outcome == HookPolled
