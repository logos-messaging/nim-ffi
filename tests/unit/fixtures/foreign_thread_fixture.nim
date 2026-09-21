## Fixture for test_foreign_thread. It calls CBOR method entry points and `poll`
## from threads that the Nim runtime does not know.

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

proc replyString(msg: ptr NimFfiMsg): string =
  var bytes = newSeq[byte](int(msg.len))
  if msg.len > 0:
    copyMem(addr bytes[0], msg.payload, int(msg.len))
  return cborDecode(bytes, string).valueOr:
    ""

proc makeCtx(tag: string): FFICtxToken =
  var req = cborEncode(ThreadedcborCreateCtorReq(cfg: ThreadConfig(tag: tag)))
  var token: FFICtxToken
  var reqId: uint64
  doAssert threadedcbor_create(
    cast[ptr byte](addr req[0]), csize_t(req.len), addr token, addr reqId
  ) == RET_OK
  doAssert not token.isNil()
  var msg: ptr NimFfiMsg
  doAssert threadedcbor_poll(token, 5000, addr msg) == RET_OK
  doAssert msg.kind == MsgReply and msg.id == reqId and msg.retCode == RET_OK
  return token

# createThread registers the thread with the GC, which hides the bug; use the platform API.
{.
  emit: """
typedef int (*NimFfiEchoFn)(void*, const void*, size_t, unsigned long long*);
typedef int (*NimFfiPollFn)(void*, int, const void**);

typedef struct {
  void* fn; void* poll; void* ctx; const void* req; size_t reqLen;
  unsigned long long reqId; const void* msg; int ret; int pollRet;
} NimFfiForeignCall;

/* Submits and polls on the same unregistered thread: both must work there. */
static void nimffi_foreign_body(NimFfiForeignCall* c) {
  c->ret = ((NimFfiEchoFn)c->fn)(c->ctx, c->req, c->reqLen, &c->reqId);
  if (c->ret == 0)
    c->pollRet = ((NimFfiPollFn)c->poll)(c->ctx, 5000, &c->msg);
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
    void* fn, void* poll, void* ctx, const void* req, size_t reqLen,
    unsigned long long* reqId, const void** msg, int* pollRet) {
  NimFfiForeignCall c;
  HANDLE t;
  c.fn = fn; c.poll = poll; c.ctx = ctx; c.req = req; c.reqLen = reqLen;
  c.reqId = 0; c.msg = (void*)0; c.ret = -1; c.pollRet = -1;
  t = CreateThread(NULL, 0, nimffi_foreign_thread_main, &c, 0, NULL);
  if (t == NULL) return -2;
  WaitForSingleObject(t, INFINITE);
  CloseHandle(t);
  *reqId = c.reqId; *msg = c.msg; *pollRet = c.pollRet;
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
    void* fn, void* poll, void* ctx, const void* req, size_t reqLen,
    unsigned long long* reqId, const void** msg, int* pollRet) {
  NimFfiForeignCall c;
  pthread_t t;
  c.fn = fn; c.poll = poll; c.ctx = ctx; c.req = req; c.reqLen = reqLen;
  c.reqId = 0; c.msg = (void*)0; c.ret = -1; c.pollRet = -1;
  if (pthread_create(&t, (void*)0, nimffi_foreign_thread_main, &c) != 0) return -2;
  pthread_join(t, (void*)0);
  *reqId = c.reqId; *msg = c.msg; *pollRet = c.pollRet;
  return c.ret;
}
"""
  .}

proc nimffi_call_on_foreign_thread(
  fn, poll, ctx, req: pointer,
  reqLen: csize_t,
  reqId: ptr culonglong,
  msg: ptr pointer,
  pollRet: ptr cint,
): cint {.importc, nodecl.}

type
  EchoExport = proc(
    ctxToken: FFICtxToken, reqCbor: ptr byte, reqCborLen: csize_t, reqIdOut: ptr uint64
  ): cint {.cdecl, raises: [].}
  PollExport = proc(
    ctxToken: FFICtxToken, timeoutMs: int32, msg: ptr ptr NimFfiMsg
  ): cint {.cdecl, raises: [].}

type ForeignReply = object
  rc: cint
  pollRet: cint
  reqId: uint64
  msg: ptr NimFfiMsg ## Valid until the next poll of the context.

proc callOnForeignThread(ctx: FFICtxToken, req: var seq[byte]): ForeignReply =
  ## The exports go to C as opaque pointers; only the typedefs above can drift.
  let echoExport: EchoExport = threadedcbor_echo
  let pollExport: PollExport = threadedcbor_poll
  var reply: ForeignReply
  var reqId: culonglong
  var msg: pointer
  reply.rc = nimffi_call_on_foreign_thread(
    cast[pointer](echoExport),
    cast[pointer](pollExport),
    cast[pointer](ctx),
    cast[pointer](addr req[0]),
    csize_t(req.len),
    addr reqId,
    addr msg,
    addr reply.pollRet,
  )
  reply.reqId = uint64(reqId)
  reply.msg = cast[ptr NimFfiMsg](msg)
  return reply

proc runScenario(tag: string, rounds: int): bool =
  ## One context, `rounds` calls, each on its own fresh platform thread.
  let ctx = makeCtx(tag)
  for i in 0 ..< rounds:
    var req = cborEncode(ThreadedcborEchoReq(text: "call " & $i))

    let reply = callOnForeignThread(ctx, req)
    var good = reply.rc == RET_OK and reply.pollRet == RET_OK and not reply.msg.isNil()
    var text = ""
    if good:
      text = replyString(reply.msg)
      good =
        reply.msg.kind == MsgReply and reply.msg.id == reply.reqId and
        reply.msg.retCode == RET_OK and text == tag & ":call " & $i

    if not good:
      echo tag,
        ": round ", i, " failed: rc=", reply.rc, " poll=", reply.pollRet, " text=", text
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
