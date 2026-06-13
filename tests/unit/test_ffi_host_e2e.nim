## End-to-end cross-thread test for {.ffiHost.} (roadmap #1, increment 4).
##
## Proves the full bridge under the real FFI thread + the *exported* C ABI:
##   request -> {.ffi.} handler awaits a {.ffiHost.} call -> library invokes the
##   host fn ON the FFI thread -> host hands the work to a SEPARATE worker thread
##   (non-blocking) -> worker answers via the exported <lib>_host_complete ->
##   reqSignal wakes the loop -> drain completes the future on the loop thread ->
##   handler resumes -> callback fires.
##
## The host answering from a different thread than the FFI loop is the property
## the in-thread macro test can't cover.

import std/[locks, atomics]
import unittest2
import results
import ffi

type TestLib = object

# NB: this drives the runtime bridge directly (registerHostFn / completeHostCall),
# not the exported C shims `<lib>_register_host_fn` / `<lib>_host_complete` — those
# need an --app:lib build (declareLibrary emits an importc NimMain) and are verified
# separately by the symbol check on the timer library. The shims are thin wrappers
# over exactly the two procs used here.

# The host implements this; a {.ffi.} handler awaits it.
proc lookupHost(key: string): Future[Result[string, string]] {.ffiHost.}

# A {.ffi.}-style request whose handler depends on the host's answer.
registerReqFFI(HostCallRequest, lib: ptr TestLib):
  proc(key: cstring): Future[Result[string, string]] {.async.} =
    let v = (await lookupHost($key)).valueOr:
      return err("host failed: " & error)
    return ok("got:" & v)

# --- the host, answering on a worker thread --------------------------------
# The host fn runs on the FFI thread, so it must NOT block: it copies the
# request and hands (token, key) to a worker via a channel, then returns. The
# worker answers later through the exported <lib>_host_complete.
var gHostJobs: Channel[tuple[token: uint64, key: string]]
var gCtx: Atomic[pointer]

proc lookupHostFnImpl(
    token: uint64, req: ptr cchar, reqLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  var key = newString(int(reqLen))
  if reqLen > 0'u:
    copyMem(addr key[0], req, int(reqLen))
  try:
    gHostJobs.send((token: token, key: key))
  except Exception:
    discard

proc hostWorker(_: pointer) {.thread.} =
  while true:
    let job = gHostJobs.recv()
    if job.token == 0'u64: # sentinel: shut down
      break
    let answer = "reply:" & job.key
    completeHostCall(
      cast[ptr FFIContext[TestLib]](gCtx.load()),
      job.token,
      RET_OK,
      cast[ptr cchar](unsafeAddr answer[0]),
      csize_t(answer.len),
    )

# --- blocking callback capture (same shape as test_ffi_context) -------------
type CallbackData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  msg: array[1024, byte]
  msgLen: int

proc testCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
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

proc waitCallback(d: var CallbackData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc callbackBytes(d: var CallbackData): seq[byte] =
  var b = newSeq[byte](d.msgLen)
  if d.msgLen > 0:
    copyMem(addr b[0], addr d.msg[0], d.msgLen)
  return b

suite "ffiHost end-to-end (cross-thread)":
  test "handler awaits a host fn answered from another thread":
    gHostJobs.open()
    var pool: FFIContextPool[TestLib]
    let ctx = pool.createFFIContext().valueOr:
      assert false, "createFFIContext failed: " & $error
      return
    gCtx.store(ctx)

    check registerHostFn(ctx[].hostRegistry, "lookup_host", lookupHostFnImpl, nil)

    var worker: Thread[pointer]
    createThread(worker, hostWorker, nil)

    var d = CallbackData()
    d.lock.initLock()
    d.cond.initCond()

    check sendRequestToFFIThread(
      ctx, HostCallRequest.ffiNewReq(testCallback, addr d, "session".cstring)
    )
      .isOk()
    waitCallback(d)

    check d.retCode == RET_OK
    # The {.ffi.} OK payload is CBOR-encoded (registerReqFFI returns seq[byte]).
    check cborDecode(callbackBytes(d), string).value == "got:reply:session"

    # Shut the worker down, then tear the context down.
    gHostJobs.send((token: 0'u64, key: ""))
    joinThread(worker)
    d.cond.deinitCond()
    d.lock.deinitLock()
    gHostJobs.close()
    check pool.destroyFFIContext(ctx).isOk()
