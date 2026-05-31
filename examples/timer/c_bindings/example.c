// Native (zero-serialization, same-process) C example for the timer library.
//
// This is the in-process path: the C host links libmy_timer directly and calls
// the native `<name>` entry points, passing `{.ffi.}` types as plain C structs
// by value. No CBOR — arguments are deep-copied across the FFI thread boundary,
// and a struct return arrives at the callback as a typed `const <Type>*`.
//
// Each call delivers its result to a callback that we block on with a condvar
// (every call is dispatched on the library's FFI thread, so the result is not
// ready until the callback fires). A struct return is valid only for the
// callback's lifetime — read it there; the library frees it afterwards.
//
// For the cross-process / cross-machine path (CBOR over a socket), see ../ipc/.
#include "my_timer.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

// --- one-shot blocking result capture ---------------------------------------
typedef struct {
  int ret, done;
  char text[512]; // a string return, or copied-out struct fields
  long itemCount;
  int hasNote;
  pthread_mutex_t mu;
  pthread_cond_t cv;
} Resp;

static void resp_init(Resp *r) {
  memset(r, 0, sizeof(*r));
  pthread_mutex_init(&r->mu, NULL);
  pthread_cond_init(&r->cv, NULL);
}
static void resp_done(Resp *r) {
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}
static void resp_wait(Resp *r) {
  pthread_mutex_lock(&r->mu);
  while (!r->done) pthread_cond_wait(&r->cv, &r->mu);
  pthread_mutex_unlock(&r->mu);
}

// Acknowledges a call with no payload we care about (ctor) or an error.
static void cb_ack(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  if (ret == RET_ERR && msg) {
    size_t n = len < sizeof(r->text) - 1 ? len : sizeof(r->text) - 1;
    memcpy(r->text, msg, n);
    r->text[n] = 0;
  }
  resp_done(r);
}
// String return (version): msg is the raw bytes.
static void cb_string(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  size_t n = len < sizeof(r->text) - 1 ? len : sizeof(r->text) - 1;
  if (msg) memcpy(r->text, msg, n);
  r->text[n] = 0;
  resp_done(r);
}
// EchoResponse return: msg is a `const EchoResponse*` (read it here).
static void cb_echo(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  if (ret == RET_OK) {
    const EchoResponse *e = (const EchoResponse *)msg;
    snprintf(r->text, sizeof(r->text), "echoed=%s timerName=%s", e->echoed,
             e->timerName);
  }
  resp_done(r);
  (void)len;
}
// ComplexResponse return: msg is a `const ComplexResponse*`.
static void cb_complex(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  if (ret == RET_OK) {
    const ComplexResponse *c = (const ComplexResponse *)msg;
    snprintf(r->text, sizeof(r->text), "%s", c->summary);
    r->itemCount = c->itemCount;
    r->hasNote = c->hasNote;
  }
  resp_done(r);
  (void)len;
}

int main(void) {
  // 1) Construct: TimerConfig by value (its `name: string` is a `const char*`).
  Resp cr;
  resp_init(&cr);
  TimerConfig cfg = {.name = "c-native-demo"};
  void *ctx = my_timer_create(cfg, cb_ack, &cr);
  resp_wait(&cr);
  if (!ctx || cr.ret != RET_OK) {
    fprintf(stderr, "create failed (ret=%d): %s\n", cr.ret, cr.text);
    return 1;
  }
  printf("created timer ctx=%p\n", ctx);

  // 2) String return.
  Resp vr;
  resp_init(&vr);
  if (my_timer_version(ctx, cb_string, &vr) == RET_OK) {
    resp_wait(&vr);
    printf("version: %s\n", vr.text);
  }

  // 3) Struct param + typed struct return (EchoResponse).
  Resp er;
  resp_init(&er);
  EchoRequest req = {.message = "hello from C", .delayMs = 5};
  if (my_timer_echo(ctx, cb_echo, &er, req) == RET_OK) {
    resp_wait(&er);
    printf("echo: %s\n", er.text);
  }

  // 4) Deeply nested param + typed struct return (ComplexResponse).
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
  if (my_timer_complex(ctx, cb_complex, &xr, creq) == RET_OK) {
    resp_wait(&xr);
    printf("complex: itemCount=%ld hasNote=%d summary=\"%s\"\n", xr.itemCount,
           xr.hasNote, xr.text);
  }

  // 5) Tear down the context (joins the FFI thread).
  my_timer_destroy(ctx);
  printf("destroyed; done.\n");
  return 0;
}
