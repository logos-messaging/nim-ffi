## How a host waits on a wake handle, per OS (epoll / parent kqueue + select /
## WaitForMultipleObjects). Not named `test_*`, so `discoverUnitTests` skips it.

when defined(linux) or defined(android):
  import std/[posix, epoll]

  proc hostSeesReady*(handle: int, timeoutMs: int): bool =
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

  proc hostSeesReady*(handle: int, timeoutMs: int): bool =
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

  proc hostSeesReady*(handle: int, timeoutMs: int): bool =
    let viaKqueue = parentKqueueSeesReady(handle, timeoutMs)
    let viaSelect = selectSeesReady(handle, timeoutMs)
    doAssert viaKqueue == viaSelect, "parent kqueue and select disagree"
    return viaKqueue

proc closeHostHandle*(handle: int) =
  when defined(windows):
    discard closeHandle(cast[Handle](handle))
  else:
    discard posix.close(cint(handle))
