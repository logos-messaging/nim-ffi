## Fixture for test_foreign_thread. It calls CBOR method entry points from
## threads that the Nim runtime does not know.

import std/[locks, strutils]
import results
import ffi

type ThreadLib = object
  tag: string

# This fixture links as an executable, so the dylib NimMain symbol needs a stub.
{.emit: "void libthreadedcborNimMain(void) {}".}

declareLibrary("threadedcbor", ThreadLib)

type ThreadConfig {.ffi.} = object
  tag: string

proc threadedcbor_create*(
    cfg: ThreadConfig
): Future[Result[ThreadLib, string]] {.ffiCtor.} =
  return ok(ThreadLib(tag: cfg.tag))

proc threadedcbor_echo*(
    lib: ThreadLib, text: string
): Future[Result[string, string]] {.ffi.} =
  ## The string decode allocates GC memory on the caller thread: the case under test.
  return ok(lib.tag & ":" & text)

proc threadedcbor_destroy*(lib: ThreadLib) {.ffiDtor.} =
  discard

genBindings()

type ReplyData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  payload: seq[byte]

proc initReplyData(d: var ReplyData) =
  d.lock.initLock()
  d.cond.initCond()

proc deinitReplyData(d: var ReplyData) =
  d.cond.deinitCond()
  d.lock.deinitLock()

proc waitReply(d: var ReplyData) =
  acquire(d.lock)
  while not d.called:
    wait(d.cond, d.lock)
  release(d.lock)

proc onReply(
    ret: cint, msg: ptr cchar, len: csize_t, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  if ret == RET_STALE_WARN:
    return
  let d = cast[ptr ReplyData](ud)
  acquire(d[].lock)
  d[].payload = newSeq[byte](int(len))
  if len > 0 and not msg.isNil():
    copyMem(addr d[].payload[0], msg, int(len))
  d[].retCode = ret
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc replyString(d: var ReplyData): string =
  cborDecode(d.payload, string).valueOr:
    ""

proc makeCtx(tag: string): FFICtxToken =
  var d: ReplyData
  initReplyData(d)
  defer:
    deinitReplyData(d)

  var req = cborEncode(ThreadedcborCreateCtorReq(cfg: ThreadConfig(tag: tag)))
  let token =
    threadedcbor_create(cast[ptr byte](addr req[0]), csize_t(req.len), onReply, addr d)
  doAssert not token.isNil()
  waitReply(d)
  doAssert d.retCode == RET_OK
  token

# createThread registers the thread with the GC, which hides the bug; use the platform API.
{.
  emit: """
typedef int (*NimFfiEchoFn)(void*, void*, void*, const void*, size_t);

typedef struct {
  void* fn; void* ctx; void* cb; void* ud; const void* req; size_t reqLen; int ret;
} NimFfiForeignCall;

static void nimffi_foreign_body(NimFfiForeignCall* c) {
  c->ret = ((NimFfiEchoFn)c->fn)(c->ctx, c->cb, c->ud, c->req, c->reqLen);
}
"""
.}

when defined(windows):
  {.
    emit: """/*INCLUDESECTION*/
#include <windows.h>
"""
  .}
  {.
    emit: """
static DWORD WINAPI nimffi_foreign_thread_main(LPVOID arg) {
  nimffi_foreign_body((NimFfiForeignCall*)arg);
  return 0;
}

int nimffi_call_on_foreign_thread(
    void* fn, void* ctx, void* cb, void* ud, const void* req, size_t reqLen) {
  NimFfiForeignCall c;
  HANDLE t;
  c.fn = fn; c.ctx = ctx; c.cb = cb; c.ud = ud; c.req = req; c.reqLen = reqLen;
  c.ret = -1;
  t = CreateThread(NULL, 0, nimffi_foreign_thread_main, &c, 0, NULL);
  if (t == NULL) return -2;
  WaitForSingleObject(t, INFINITE);
  CloseHandle(t);
  return c.ret;
}
"""
  .}
else:
  {.
    emit: """/*INCLUDESECTION*/
#include <pthread.h>
"""
  .}
  {.
    emit: """
static void* nimffi_foreign_thread_main(void* arg) {
  nimffi_foreign_body((NimFfiForeignCall*)arg);
  return (void*)0;
}

int nimffi_call_on_foreign_thread(
    void* fn, void* ctx, void* cb, void* ud, const void* req, size_t reqLen) {
  NimFfiForeignCall c;
  pthread_t t;
  c.fn = fn; c.ctx = ctx; c.cb = cb; c.ud = ud; c.req = req; c.reqLen = reqLen;
  c.ret = -1;
  if (pthread_create(&t, (void*)0, nimffi_foreign_thread_main, &c) != 0) return -2;
  pthread_join(t, (void*)0);
  return c.ret;
}
"""
  .}

proc nimffi_call_on_foreign_thread(
  fn, ctx, cb, ud, req: pointer, reqLen: csize_t
): cint {.importc, nodecl.}

type EchoExport = proc(
  ctxToken: FFICtxToken,
  callback: FFICallBack,
  userData: pointer,
  reqCbor: ptr byte,
  reqCborLen: csize_t,
): cint {.cdecl, raises: [].}

proc callOnForeignThread(ctx: FFICtxToken, req: var seq[byte], d: ptr ReplyData): cint =
  ## The export goes to C as an opaque pointer; only the typedef above can drift.
  let echoExport: EchoExport = threadedcbor_echo
  nimffi_call_on_foreign_thread(
    cast[pointer](echoExport),
    cast[pointer](ctx),
    cast[pointer](onReply),
    cast[pointer](d),
    cast[pointer](addr req[0]),
    csize_t(req.len),
  )

proc runScenario(tag: string, rounds: int): bool =
  ## One context, `rounds` calls, each on its own fresh platform thread.
  let ctx = makeCtx(tag)
  for i in 0 ..< rounds:
    var d: ReplyData
    initReplyData(d)
    var req = cborEncode(ThreadedcborEchoReq(text: "call " & $i))

    let rc = callOnForeignThread(ctx, req, addr d)
    waitReply(d)
    let text = replyString(d)
    let good = rc == RET_OK and d.retCode == RET_OK and text == tag & ":call " & $i

    deinitReplyData(d)
    if not good:
      echo tag, ": round ", i, " failed: rc=", rc, " ret=", d.retCode, " text=", text
      return false

  if ThreadLibFFIPool.destroyFFIContext(ThreadLibFFIPool.resolveCtx(ctx)).isErr():
    echo tag, ": destroyFFIContext failed"
    return false
  return true

proc main(): int =
  # Several rounds prove the registration is per thread, not once per process.
  if not runScenario("single", 1):
    return 1
  if not runScenario("multi", 8):
    return 1
  return 0

quit(main())
