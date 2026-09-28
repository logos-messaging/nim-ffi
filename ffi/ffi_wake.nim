## Level-triggered wake signal with a handle the host can wait on.
##
## `fire` makes the handle ready and it stays ready until `clear`, whoever waits
## and however often. Each OS uses its own primitive, for the handle and for the
## blocking `waitFor` alike:
##
## ================  ===============================  =====================================
## OS                handle                           the host waits with
## ================  ===============================  =====================================
## Linux, Android    eventfd                          epoll, poll, select
## macOS, iOS, BSD   kqueue holding one EVFILT_USER   a parent kqueue, poll, select
## Windows           manual-reset Event               WaitForSingleObject / MultipleObjects
## ================  ===============================  =====================================
##
## Every proc is free of Nim allocations, so foreign threads may call them.

import results

const
  wakeEventFd = defined(linux) or defined(android)
  wakeKqueue = defined(macosx) or defined(ios) or defined(freebsd) or defined(dragonfly)
  wakeWinEvent = defined(windows)

when wakeEventFd:
  import std/[posix, oserrors, monotimes]

  proc eventfd(initval: cuint, flags: cint): cint {.importc, header: "<sys/eventfd.h>".}

  var
    EFD_CLOEXEC {.importc, header: "<sys/eventfd.h>".}: cint
    EFD_NONBLOCK {.importc, header: "<sys/eventfd.h>".}: cint
elif wakeKqueue:
  import std/[posix, kqueue, oserrors, monotimes]

  const UserEventIdent = 1'u
elif wakeWinEvent:
  import std/[winlean, oserrors]

  proc resetEvent(
    hEvent: Handle
  ): WINBOOL {.stdcall, dynlib: "kernel32", importc: "ResetEvent".}

else:
  {.error: "ffi_wake: no wake primitive for this OS".}

type WakeSignal* = object
  ## Zero value is "not initialised": every proc is then a no-op, so a fd of 0 is
  ## never mistaken for ours.
  ready: bool
  when wakeEventFd:
    efd: cint
  elif wakeKqueue:
    kq: cint
  elif wakeWinEvent:
    event: Handle

const WakeNoHandle* = -1

when wakeKqueue:
  proc userEvent(flags: cushort, fflags: cuint): KEvent =
    return KEvent(
      ident: UserEventIdent,
      filter: EVFILT_USER,
      flags: flags,
      fflags: fflags,
      data: 0,
      udata: nil,
    )

  proc submit(kq: cint, changes: var openArray[KEvent]): cint =
    ## Applies the changes, in order, without retrieving events.
    while true:
      let res = kevent(kq, addr changes[0], cint(changes.len), nil, 0, nil)
      if res == -1 and errno == EINTR:
        continue
      return res

proc init*(w: var WakeSignal): Result[void, string] =
  if w.ready:
    return ok()

  when wakeEventFd:
    let fd = eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK)
    if fd == -1:
      return err("eventfd failed: " & osErrorMsg(osLastError()))
    w.efd = fd
  elif wakeKqueue:
    let kq = kqueue()
    if kq == -1:
      return err("kqueue failed: " & osErrorMsg(osLastError()))
    discard fcntl(kq, F_SETFD, FD_CLOEXEC)
    # No EV_CLEAR: a triggered event stays active across retrievals, which is
    # what keeps the kqueue fd ready until `clear`.
    var add = [userEvent(EV_ADD, 0)]
    if submit(kq, add) == -1:
      let msg = osErrorMsg(osLastError())
      discard posix.close(kq)
      return err("kevent EV_ADD failed: " & msg)
    w.kq = kq
  elif wakeWinEvent:
    let ev = createEvent(nil, 1, 0, nil) # manual reset, initially unset
    if ev == Handle(0):
      return err("CreateEvent failed: " & osErrorMsg(osLastError()))
    w.event = ev

  w.ready = true
  return ok()

proc close*(w: var WakeSignal) =
  if not w.ready:
    return
  w.ready = false
  when wakeEventFd:
    discard posix.close(w.efd)
  elif wakeKqueue:
    discard posix.close(w.kq)
  elif wakeWinEvent:
    discard closeHandle(w.event)

proc handle*(w: WakeSignal): int =
  ## The fd, or the Event `HANDLE` on Windows, for the host's own wait call. The
  ## host must only wait on it: never read, write or close it.
  if not w.ready:
    return WakeNoHandle
  when wakeEventFd:
    return int(w.efd)
  elif wakeKqueue:
    return int(w.kq)
  elif wakeWinEvent:
    return cast[int](w.event)

proc fire*(w: var WakeSignal) {.raises: [].} =
  ## Any thread. Firing an already fired signal changes nothing.
  if not w.ready:
    return
  when wakeEventFd:
    var one = 1'u64
    while true:
      let n = posix.write(w.efd, addr one, sizeof(one))
      # EAGAIN: the counter is saturated, so the fd is ready already.
      if n == -1 and errno == EINTR:
        continue
      break
  elif wakeKqueue:
    var trigger = [userEvent(0, NOTE_TRIGGER)]
    discard submit(w.kq, trigger)
  elif wakeWinEvent:
    discard setEvent(w.event)

proc clear*(w: var WakeSignal) {.raises: [].} =
  ## Any thread. A `fire` racing with `clear` may be lost, so the caller re-checks
  ## its own state after clearing and before it waits.
  if not w.ready:
    return
  when wakeEventFd:
    var counter = 0'u64
    while true:
      let n = posix.read(w.efd, addr counter, sizeof(counter))
      # EAGAIN: nothing was fired.
      if n == -1 and errno == EINTR:
        continue
      break
  elif wakeKqueue:
    # Re-adding is the one reset that FreeBSD and XNU agree on. One syscall, so a
    # racing `fire` has the smallest window in which to find no event.
    var reset = [userEvent(EV_DELETE, 0), userEvent(EV_ADD, 0)]
    discard submit(w.kq, reset)
  elif wakeWinEvent:
    discard resetEvent(w.event)

proc waitFor*(w: var WakeSignal, timeoutMs: int): bool {.raises: [].} =
  ## Blocks the calling thread until the signal is fired. 0 only checks, negative
  ## waits forever. Does not clear. False on timeout, or when not initialised.
  if not w.ready:
    return false

  when wakeWinEvent:
    var ms = INFINITE
    if timeoutMs >= 0:
      ms = int32(min(timeoutMs, int(high(int32)) - 1))
    return waitForSingleObject(w.event, ms) == WAIT_OBJECT_0
  else:
    let start = getMonoTime().ticks
    var remainingMs = timeoutMs
    while true:
      when wakeEventFd:
        var pfd = TPollfd(fd: w.efd, events: POLLIN, revents: 0)
        var slice = cint(-1)
        if remainingMs >= 0:
          slice = cint(min(remainingMs, int(high(cint))))
        let res = posix.poll(addr pfd, Tnfds(1), slice)
      elif wakeKqueue:
        var got: KEvent
        var ts: Timespec
        var tsPtr: ptr Timespec = nil
        if remainingMs >= 0:
          ts.tv_sec = posix.Time(remainingMs div 1000)
          ts.tv_nsec = (remainingMs mod 1000) * 1_000_000
          tsPtr = addr ts
        let res = kevent(w.kq, nil, 0, addr got, 1, tsPtr)

      if res > 0:
        return true
      if res == 0:
        return false
      if errno != EINTR:
        return false
      if timeoutMs >= 0:
        let elapsedMs = int((getMonoTime().ticks - start) div 1_000_000)
        if elapsedMs >= timeoutMs:
          return false
        remainingMs = timeoutMs - elapsedMs
