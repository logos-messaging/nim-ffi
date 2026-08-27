## Shared harness for the unit tests: request plumbing, wait loops and the
## watchdog. Not named `test_*`, so `discoverUnitTests` does not run it.

import std/[atomics, locks, os]
import ffi

proc encodedPtr*(bytes: var seq[byte]): ptr byte =
  ## `addr bytes[0]` is a defect on an empty seq, and a request may carry none.
  if bytes.len == 0:
    nil
  else:
    cast[ptr byte](addr bytes[0])

proc noopCallback*(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

proc waitFlag*(flag: var Atomic[bool], timeoutMs = 5000): bool =
  let deadline = Moment.now() + timeoutMs.milliseconds
  while not flag.load():
    if Moment.now() >= deadline:
      return false
    os.sleep(5)
  true

proc waitSlotFree*[T](ctx: ptr FFIContext[T]) =
  ## Waits out the claim for a recycle driven by some path other than `recycleFFIContext`, which returns with the slot free.
  let deadline = Moment.now() + 5.seconds
  while ctx.isInUse() and Moment.now() < deadline:
    os.sleep(1)

type CallbackData* = object
  ## Reply landing pad for a request: the callback runs on the FFI thread, so
  ## the test waits on the condvar rather than polling.
  lock*: Lock
  cond*: Cond
  called*: bool
  retCode*: cint
  msg*: array[1024, byte]
  msgLen*: int

proc initCallbackData*(d: var CallbackData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitCallbackData*(d: var CallbackData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

template setupCallbackData*(name: untyped) =
  var name: CallbackData
  initCallbackData(name)
  defer:
    deinitCallbackData(name)

proc testCallback*(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  # A progress ping is not a terminal answer; skip it here.
  if retCode == RET_STALE_WARN:
    return
  let d = cast[ptr CallbackData](userData)
  acquire(d[].lock)
  d[].retCode = retCode
  let n = min(int(len), d[].msg.len)
  if n > 0 and not msg.isNil:
    copyMem(addr d[].msg[0], msg, n)
  d[].msgLen = n
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc waitCallback*(d: var CallbackData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc waitCallbackTimeout*(d: var CallbackData, timeoutMs: int): bool =
  ## `waitCallback` for a reply that may never come; false on timeout.
  let deadline = Moment.now() + timeoutMs.milliseconds
  while true:
    acquire(d.lock)
    let done = d.called
    release(d.lock)
    if done:
      return true
    if Moment.now() >= deadline:
      return false
    os.sleep(10)

proc resetCalled*(d: var CallbackData) =
  acquire(d.lock)
  d.called = false
  release(d.lock)

proc wasCalled*(d: var CallbackData): bool =
  acquire(d.lock)
  let called = d.called
  release(d.lock)
  called

proc payload*(d: var CallbackData): seq[byte] =
  var b = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr b[0], addr d.msg[0], d.msgLen)
  b

proc rawText*(d: var CallbackData): string =
  ## The reply bytes as text: an error message, or a CBOR payload to decode.
  var s = newString(d.msgLen)
  if d.msgLen > 0:
    copyMem(addr s[0], addr d.msg[0], d.msgLen)
  s

proc okString*(d: var CallbackData): string =
  ## The CBOR-decoded `string` an OK reply carries; asserts the request succeeded,
  ## so a failure reports the error text instead of an empty string.
  doAssert d.retCode == RET_OK,
    "okString on retCode " & $d.retCode & " (msg=" & d.rawText() & ")"
  cborDecode(d.payload(), string).valueOr:
    ""

proc watchdogBody(args: (int, cstring)) {.thread.} =
  os.sleep(args[0])
  echo "watchdog: ", args[1]
  quit(1)

var watchdog: Thread[(int, cstring)]

proc startWatchdog*(timeoutMs: int, message: cstring) =
  ## For a file whose unpatched behaviour is a hang: the process must die on its
  ## own, or CI blocks instead of failing.
  createThread(watchdog, watchdogBody, (timeoutMs, message))
