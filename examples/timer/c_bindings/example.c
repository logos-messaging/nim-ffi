// Native (zero-serialization, same-process) C example for the timer library.
//
// This is the in-process path: the C host links libmy_timer directly and calls
// the native `<name>` entry points, passing `{.ffi.}` types as plain C structs
// by value. No CBOR — arguments are deep-copied across the FFI thread boundary
// as flat C-POD graphs. Each call delivers its result to a callback that we
// block on with a condvar (every call is dispatched on the library's FFI
// thread, so the result is not ready until the callback fires).
//
// For the cross-process / cross-machine path (CBOR over a socket), see
// ../ipc/.
#include "my_timer.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

// --- one-shot blocking response capture -------------------------------------
typedef struct {
  int ret;
  char buf[2048];
  size_t len;
  int done;
  pthread_mutex_t mu;
  pthread_cond_t cv;
} Resp;

static void resp_init(Resp *r) {
  memset(r, 0, sizeof(*r));
  pthread_mutex_init(&r->mu, NULL);
  pthread_cond_init(&r->cv, NULL);
}

// Native ABI: on RET_OK (msg, len) is the raw return value (for a string-
// returning proc, the bytes; for a struct-returning proc, its CBOR encoding);
// on RET_ERR it is the raw error text. We copy it so it outlives the callback.
static void on_result(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = (Resp *)ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  size_t n = len < sizeof(r->buf) - 1 ? len : sizeof(r->buf) - 1;
  if (msg && n) memcpy(r->buf, msg, n);
  r->buf[n] = '\0';
  r->len = len;
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}

static void resp_wait(Resp *r) {
  pthread_mutex_lock(&r->mu);
  while (!r->done) pthread_cond_wait(&r->cv, &r->mu);
  pthread_mutex_unlock(&r->mu);
}

int main(void) {
  // 1) Construct the library context. The ctor takes a TimerConfig by value;
  //    its `name: string` field is a plain `const char*` on the C side.
  Resp cr;
  resp_init(&cr);
  TimerConfig cfg = {.name = "c-native-demo"};
  void *ctx = my_timer_create(cfg, on_result, &cr);
  resp_wait(&cr);
  if (!ctx || cr.ret != RET_OK) {
    fprintf(stderr, "create failed (ret=%d): %s\n", cr.ret, cr.buf);
    return 1;
  }
  printf("created timer ctx=%p\n", ctx);

  // 2) Synchronous-shaped call: version returns a plain string, delivered raw.
  Resp vr;
  resp_init(&vr);
  if (my_timer_version(ctx, on_result, &vr) == RET_OK) {
    resp_wait(&vr);
    printf("version: %s\n", vr.buf);
  }

  // 3) Struct param by value: EchoRequest { const char* message; int64 delayMs }.
  //    The library sleeps delayMs on its chronos loop, then echoes the message.
  Resp er;
  resp_init(&er);
  EchoRequest req = {.message = "hello from C", .delayMs = 5};
  if (my_timer_echo(ctx, on_result, &er, req) == RET_OK) {
    resp_wait(&er);
    // EchoResponse is a struct return, delivered as CBOR on the native path;
    // the echoed message appears verbatim inside the payload bytes.
    printf("echo ret=%d (%zu-byte response, contains \"%s\")\n", er.ret, er.len,
           strstr(er.buf, "hello from C") ? "hello from C" : "<not found>");
  }

  // 4) Deeply nested struct: seq<struct>, seq<string>, Option<string>, Option<int>.
  //    Demonstrates that the whole graph is deep-copied across the boundary.
  Resp xr;
  resp_init(&xr);
  EchoRequest msgs[2] = {
      {.message = "one", .delayMs = 0},
      {.message = "two", .delayMs = 0},
  };
  const char *tags[1] = {"demo"};
  ComplexRequest creq = {
      .messages = msgs,
      .messages_len = 2,
      .tags = tags,
      .tags_len = 1,
      .note_present = 1,
      .note = "a note",
      .retries_present = 1,
      .retries = 3,
  };
  if (my_timer_complex(ctx, on_result, &xr, creq) == RET_OK) {
    resp_wait(&xr);
    printf("complex ret=%d (%zu-byte response)\n", xr.ret, xr.len);
  }

  // 5) Tear down the context (joins the FFI thread).
  my_timer_destroy(ctx);
  printf("destroyed; done.\n");
  return 0;
}
