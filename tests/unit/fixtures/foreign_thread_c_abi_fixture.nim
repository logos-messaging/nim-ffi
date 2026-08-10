## Fixture for test_foreign_thread_c_abi. It calls `abi = c` method entry
## points from threads that the Nim runtime does not know.

import std/[locks, strutils]
import results
import ffi

type ThreadLib = object
  tag: string

# declareLibrary imports the NimMain symbol of the dylib. This fixture links as
# an executable, so it must supply an empty stub.
{.emit: "void libthreadedcabiNimMain(void) {}".}

declareLibrary("threadedcabi", ThreadLib, defaultABIFormat = "c")

type ThreadConfig {.ffi.} = object
  tag: string

proc threadedcabi_create*(
    cfg: ThreadConfig
): Future[Result[ThreadLib, string]] {.ffiCtor.} =
  return ok(ThreadLib(tag: cfg.tag))

proc threadedcabi_echo*(
    lib: ThreadLib, text: string
): Future[Result[string, string]] {.ffi.} =
  ## The method takes a string, so the request unpack allocates GC-managed
  ## memory on the calling thread. That is the operation under test.
  return ok(lib.tag & ":" & text)

genBindings()

type ReplyData = object
  lock: Lock
  cond: Cond
  called: bool
  retCode: cint
  text: string

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

proc onStringReply(
    err: cint, reply: cstring, errMsg: cstring, ud: pointer
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr ReplyData](ud)
  acquire(d[].lock)
  if err == RET_OK and not reply.isNil():
    d[].text = $reply
  d[].retCode = err
  d[].called = true
  signal(d[].cond)
  release(d[].lock)

proc packedWire[W, R](_: typedesc[W], envelope: R): W =
  var wire: W
  cwirePack(wire, envelope)
  wire

proc makeCtx(tag: string): FFICtxToken =
  var d: ReplyData
  initReplyData(d)
  defer:
    deinitReplyData(d)

  var wire = packedWire(
    ThreadedcabiCreateCtorReq_CWire,
    ThreadedcabiCreateCtorReq(cfg: ThreadConfig(tag: tag)),
  )
  defer:
    cwireFree(wire)

  doAssert not ThreadedcabiCreateCtorReqCAbiExport(addr wire, onStringReply, addr d)
    .isNil()
  waitReply(d)
  doAssert d.retCode == RET_OK
  # The ctor's reply text is the new ctx token as a decimal string.
  cast[FFICtxToken](parseBiggestUInt(d.text))

# Nim's createThread registers its new thread with the GC. A registered thread
# cannot show the bug. The test thread must come from the platform API.
{.
  emit: """
typedef int (*NimFfiEchoFn)(void*, void*, void*, const void*);

typedef struct {
  void* fn; void* ctx; void* cb; void* ud; const void* req; int ret;
} NimFfiForeignCall;

static void nimffi_foreign_body(NimFfiForeignCall* c) {
  c->ret = ((NimFfiEchoFn)c->fn)(c->ctx, c->cb, c->ud, c->req);
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
    void* fn, void* ctx, void* cb, void* ud, const void* req) {
  NimFfiForeignCall c;
  HANDLE t;
  c.fn = fn; c.ctx = ctx; c.cb = cb; c.ud = ud; c.req = req; c.ret = -1;
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
    void* fn, void* ctx, void* cb, void* ud, const void* req) {
  NimFfiForeignCall c;
  pthread_t t;
  c.fn = fn; c.ctx = ctx; c.cb = cb; c.ud = ud; c.req = req; c.ret = -1;
  if (pthread_create(&t, (void*)0, nimffi_foreign_thread_main, &c) != 0) return -2;
  pthread_join(t, (void*)0);
  return c.ret;
}
"""
  .}

proc nimffi_call_on_foreign_thread(
  fn, ctx, cb, ud: pointer, req: pointer
): cint {.importc, nodecl.}

proc callOnForeignThread(
    ctx: FFICtxToken, req: ptr ThreadedcabiEchoReq_CWire, d: ptr ReplyData
): cint =
  ## This proc passes the export to C as an opaque pointer. Only the typedef
  ## above can differ from the generated signature.
  nimffi_call_on_foreign_thread(
    cast[pointer](ThreadedcabiEchoReqCAbiExport),
    cast[pointer](ctx),
    cast[pointer](onStringReply),
    cast[pointer](d),
    cast[pointer](req),
  )

proc runScenario(tag: string, rounds: int): bool =
  ## Creates one context, then makes `rounds` calls to it. Each call starts a
  ## new platform thread, runs the entry point on it once, and joins it.
  let ctx = makeCtx(tag)
  for i in 0 ..< rounds:
    var d: ReplyData
    initReplyData(d)
    var req =
      packedWire(ThreadedcabiEchoReq_CWire, ThreadedcabiEchoReq(text: "call " & $i))

    let rc = callOnForeignThread(ctx, addr req, addr d)
    waitReply(d)
    let good = rc == RET_OK and d.retCode == RET_OK and d.text == tag & ":call " & $i

    cwireFree(req)
    deinitReplyData(d)
    if not good:
      echo tag, ": round ", i, " failed: rc=", rc, " ret=", d.retCode, " text=", d.text
      return false

  if ThreadLibFFIPool.destroyFFIContext(ThreadLibFFIPool.resolveCtx(ctx)).isErr():
    echo tag, ": destroyFFIContext failed"
    return false
  return true

proc main(): int =
  # Multiple rounds make sure that the registration is per-thread, not one
  # time for the process.
  if not runScenario("single", 1):
    return 1
  if not runScenario("multi", 8):
    return 1
  return 0

quit(main())
