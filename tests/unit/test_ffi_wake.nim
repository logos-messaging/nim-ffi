## The wake signal, checked through `waitFor` and through the wait call a host
## would use on the handle (epoll / parent kqueue + select / WaitForMultipleObjects).

import std/[monotimes, os, times]
import unittest2
import results
import ffi/ffi_wake

when defined(linux) or defined(android):
  import std/[posix, epoll]

  proc hostSeesReady(handle: int, timeoutMs: int): bool =
    let ep = epoll_create1(0)
    doAssert ep != -1
    defer:
      discard posix.close(ep)
    var ev = EpollEvent(events: EPOLLIN)
    doAssert epoll_ctl(ep, EPOLL_CTL_ADD, cint(handle), addr ev) == 0
    var got: EpollEvent
    return epoll_wait(ep, addr got, 1, cint(timeoutMs)) == 1

elif defined(windows):
  import std/winlean

  proc hostSeesReady(handle: int, timeoutMs: int): bool =
    var handles: WOHandleArray
    handles[0] = cast[Handle](handle)
    let res = waitForMultipleObjects(1, addr handles, 0, int32(timeoutMs))
    return res == WAIT_OBJECT_0

else:
  import std/[posix, kqueue]

  proc parentKqueueSeesReady(handle: int, timeoutMs: int): bool =
    let parent = kqueue()
    doAssert parent != -1
    defer:
      discard posix.close(parent)
    var change = KEvent(ident: uint(handle), filter: EVFILT_READ, flags: EV_ADD)
    var got: KEvent
    var ts = Timespec(
      tv_sec: posix.Time(timeoutMs div 1000), tv_nsec: (timeoutMs mod 1000) * 1_000_000
    )
    return kevent(parent, addr change, 1, addr got, 1, addr ts) == 1

  proc selectSeesReady(handle: int, timeoutMs: int): bool =
    var readSet: TFdSet
    FD_ZERO(readSet)
    FD_SET(cint(handle), readSet)
    var tv = Timeval(
      tv_sec: posix.Time(timeoutMs div 1000),
      tv_usec: Suseconds((timeoutMs mod 1000) * 1000),
    )
    return select(cint(handle + 1), addr readSet, nil, nil, addr tv) == 1

  proc hostSeesReady(handle: int, timeoutMs: int): bool =
    let viaKqueue = parentKqueueSeesReady(handle, timeoutMs)
    let viaSelect = selectSeesReady(handle, timeoutMs)
    doAssert viaKqueue == viaSelect, "parent kqueue and select disagree"
    return viaKqueue

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
