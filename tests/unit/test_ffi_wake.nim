## The wake signal, checked through `waitFor` and through the wait call a host
## would use on the handle (epoll / parent kqueue + select / WaitForMultipleObjects).

import std/[monotimes, os, times]
import unittest2
import results
import ffi/ffi_wake
import ./host_wait

proc elapsedMs(start: MonoTime): int =
  return int((getMonoTime() - start).inMilliseconds)

proc fireLater(w: ptr WakeSignal) {.thread.} =
  sleep(100)
  w[].fire()

suite "wake signal":
  test "an uninitialised signal is inert":
    var w: WakeSignal
    check w.handle() == WakeNoHandle
    w.fire()
    w.clear()
    check not w.waitFor(0)
    w.close()

  test "a new signal is not ready":
    var w: WakeSignal
    check w.init().isOk()
    defer:
      w.close()
    check w.handle() != WakeNoHandle
    check not w.waitFor(0)
    check not hostSeesReady(w.handle(), 0)

  test "init is idempotent and close releases the handle":
    var w: WakeSignal
    check w.init().isOk()
    let first = w.handle()
    check w.init().isOk()
    check w.handle() == first
    w.close()
    check w.handle() == WakeNoHandle
    w.close()

  test "fire keeps the handle ready until clear":
    var w: WakeSignal
    check w.init().isOk()
    defer:
      w.close()
    w.fire()
    for _ in 0 ..< 3:
      check w.waitFor(0)
      check hostSeesReady(w.handle(), 0)

    w.clear()
    check not w.waitFor(0)
    check not hostSeesReady(w.handle(), 0)

  test "many fires are cleared by one clear, and the signal re-arms":
    var w: WakeSignal
    check w.init().isOk()
    defer:
      w.close()
    for _ in 0 ..< 5:
      w.fire()
    w.clear()
    check not w.waitFor(0)
    check not hostSeesReady(w.handle(), 0)

    w.fire()
    check w.waitFor(0)
    check hostSeesReady(w.handle(), 0)

  test "clear without a fire is harmless":
    var w: WakeSignal
    check w.init().isOk()
    defer:
      w.close()
    w.clear()
    w.clear()
    check not w.waitFor(0)
    w.fire()
    check w.waitFor(0)

  test "waitFor returns false after its timeout":
    var w: WakeSignal
    check w.init().isOk()
    defer:
      w.close()
    let start = getMonoTime()
    check not w.waitFor(150)
    let took = elapsedMs(start)
    check took >= 100 # Windows may wake a timer tick early
    check took < 2000

  test "a fire from another thread wakes a blocked waitFor":
    var w: WakeSignal
    check w.init().isOk()
    defer:
      w.close()
    var th: Thread[ptr WakeSignal]
    let start = getMonoTime()
    createThread(th, fireLater, addr w)
    check w.waitFor(-1)
    check elapsedMs(start) < 5000
    joinThread(th)
    check hostSeesReady(w.handle(), 0)

  test "a fire from another thread wakes a host blocked on the handle":
    var w: WakeSignal
    check w.init().isOk()
    defer:
      w.close()
    var th: Thread[ptr WakeSignal]
    let start = getMonoTime()
    createThread(th, fireLater, addr w)
    check hostSeesReady(w.handle(), 5000)
    check elapsedMs(start) < 5000
    joinThread(th)
    check w.waitFor(0)

suite "host handle":
  test "the host's copy follows the signal and may be closed at any time":
    var w: WakeSignal
    check w.init().isOk()
    defer:
      w.close()
    let copy = w.hostHandle()
    check copy != WakeNoHandle
    check copy != w.handle()
    check not hostSeesReady(copy, 0)

    w.fire()
    check hostSeesReady(copy, 0)
    w.clear()
    check not hostSeesReady(copy, 0)

    closeHostHandle(copy)
    w.fire()
    check w.waitFor(0)
    let second = w.hostHandle()
    check hostSeesReady(second, 0)
    closeHostHandle(second)

  test "an uninitialised signal has no host handle":
    var w: WakeSignal
    check w.hostHandle() == WakeNoHandle
