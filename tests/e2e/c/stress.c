// Concurrency + memory stress for BOTH ABIs of one library:
//   - native (pure C): EchoRequest struct in, typed EchoResponse* back
//   - CBOR: encoded request in, CBOR EchoResponse map back
//
// Many threads hammer a shared context with both call shapes, each verifying
// the echoed message round-trips. Built to run under ASAN/TSAN to flush out
// leaks, use-after-free in the POD deep-copy/free paths, and data races.
//
//   make stress && ./stress           # plain
//   make stress SAN=address           # -fsanitize=address
//   make stress SAN=thread            # -fsanitize=thread
#include "my_timer.h"
#include "my_timer_cbor.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef STRESS_THREADS
#define STRESS_THREADS 6
#endif
#ifndef STRESS_ITERS
#define STRESS_ITERS 1500
#endif

static atomic_long g_ok;
static atomic_long g_bad;

// --- per-call blocking capture ----------------------------------------------
typedef struct {
  int ret, done;
  char echoed[128]; // copied out of the typed return / decoded from CBOR
  pthread_mutex_t mu;
  pthread_cond_t cv;
} Cap;
static void cap_init(Cap *c) {
  memset(c, 0, sizeof(*c));
  pthread_mutex_init(&c->mu, NULL);
  pthread_cond_init(&c->cv, NULL);
}
static void cap_destroy(Cap *c) {
  pthread_mutex_destroy(&c->mu);
  pthread_cond_destroy(&c->cv);
}
static void cap_reset(Cap *c) {
  pthread_mutex_lock(&c->mu);
  c->done = 0;
  c->echoed[0] = 0;
  pthread_mutex_unlock(&c->mu);
}
static void cap_wait(Cap *c) {
  pthread_mutex_lock(&c->mu);
  while (!c->done) pthread_cond_wait(&c->cv, &c->mu);
  pthread_mutex_unlock(&c->mu);
}

// Native EchoResponse return: read the typed struct in-callback.
static void native_cb(int ret, const char *msg, size_t len, void *ud) {
  Cap *c = ud;
  pthread_mutex_lock(&c->mu);
  c->ret = ret;
  if (ret == RET_OK) {
    const EchoResponse *r = (const EchoResponse *)msg;
    strncpy(c->echoed, r->echoed, sizeof(c->echoed) - 1);
  }
  c->done = 1;
  pthread_cond_signal(&c->cv);
  pthread_mutex_unlock(&c->mu);
  (void)len;
}

// --- minimal CBOR map text reader (for the CBOR EchoResponse) ---------------
static size_t cbor_item_len(const uint8_t *p, size_t len) {
  if (len < 1) return 0;
  uint8_t major = p[0] >> 5, info = p[0] & 0x1f;
  size_t head = 1;
  uint64_t arg = info;
  if (info == 24) { if (len < 2) return 0; arg = p[1]; head = 2; }
  else if (info == 25) { if (len < 3) return 0; arg = ((uint64_t)p[1] << 8) | p[2]; head = 3; }
  else if (info == 26) { if (len < 5) return 0; arg = ((uint64_t)p[1] << 24)|((uint64_t)p[2] << 16)|((uint64_t)p[3] << 8)|p[4]; head = 5; }
  else if (info == 27) { if (len < 9) return 0; arg = 0; for (int i = 1; i <= 8; i++) arg = (arg << 8) | p[i]; head = 9; }
  else if (info >= 28) return 0;
  switch (major) {
  case 0: case 1: case 7: return head;
  case 2: case 3: return head + (size_t)arg;
  case 4: { size_t off = head; for (uint64_t i = 0; i < arg; i++) { size_t n = cbor_item_len(p+off, len-off); if (!n) return 0; off += n; } return off; }
  case 5: { size_t off = head; for (uint64_t i = 0; i < arg*2; i++) { size_t n = cbor_item_len(p+off, len-off); if (!n) return 0; off += n; } return off; }
  default: return 0;
  }
}
static int cbor_get_text(const uint8_t *p, size_t len, const char *key, char *out, size_t cap) {
  if (len < 1 || (p[0] >> 5) != 5) return 0;
  uint8_t info = p[0] & 0x1f;
  if (info >= 24) return 0;
  size_t off = 1, klen = strlen(key);
  for (uint64_t i = 0; i < info; i++) {
    const uint8_t *k = p + off;
    if ((k[0] >> 5) != 3) return 0;
    uint8_t ki = k[0] & 0x1f;
    if (ki >= 24) return 0;
    const uint8_t *v = p + off + 1 + ki;
    if ((size_t)ki == klen && memcmp(k + 1, key, klen) == 0 && (v[0] >> 5) == 3) {
      uint8_t vi = v[0] & 0x1f;
      if (vi >= 24) return 0;
      size_t n = vi < cap - 1 ? vi : cap - 1;
      memcpy(out, v + 1, n);
      out[n] = 0;
      return 1;
    }
    size_t vn = cbor_item_len(v, len - (off + 1 + ki));
    if (!vn) return 0;
    off += 1 + ki + vn;
  }
  return 0;
}

// CBOR EchoResponse return: decode the "echoed" field in-callback.
static void cbor_cb(int ret, const char *msg, size_t len, void *ud) {
  Cap *c = ud;
  pthread_mutex_lock(&c->mu);
  c->ret = ret;
  if (ret == RET_OK)
    cbor_get_text((const uint8_t *)msg, len, "echoed", c->echoed, sizeof(c->echoed));
  c->done = 1;
  pthread_cond_signal(&c->cv);
  pthread_mutex_unlock(&c->mu);
}

struct Args { void *ctx; int id; };

static void *worker(void *p) {
  struct Args *a = p;
  Cap cap;
  cap_init(&cap);
  char want[128];
  for (int i = 0; i < STRESS_ITERS; i++) {
    snprintf(want, sizeof(want), "t%d-i%d", a->id, i);
    if (i & 1) {
      // native: EchoRequest in, typed EchoResponse* back
      cap_reset(&cap);
      EchoRequest req = {.message = want, .delayMs = 0};
      if (my_timer_echo(a->ctx, native_cb, &cap, req) == RET_OK) cap_wait(&cap);
    } else {
      // CBOR: { "req": { "message": want, "delayMs": 0 } }
      cap_reset(&cap);
      FfiCbor e = ffi_cbor_new();
      ffi_cbor_map(&e, 1);
      ffi_cbor_text(&e, "req");
      ffi_cbor_map(&e, 2);
      ffi_cbor_kv_text(&e, "message", want);
      ffi_cbor_kv_int(&e, "delayMs", 0);
      if (my_timer_echo_cbor(a->ctx, cbor_cb, &cap, e.buf, e.len) == RET_OK)
        cap_wait(&cap);
      ffi_cbor_free(&e);
    }
    if (cap.ret == RET_OK && strcmp(cap.echoed, want) == 0)
      atomic_fetch_add(&g_ok, 1);
    else
      atomic_fetch_add(&g_bad, 1);
  }
  cap_destroy(&cap);
  return NULL;
}

static void create_cb(int ret, const char *msg, size_t len, void *ud) {
  Cap *c = ud;
  pthread_mutex_lock(&c->mu);
  c->ret = ret;
  c->done = 1;
  pthread_cond_signal(&c->cv);
  pthread_mutex_unlock(&c->mu);
  (void)msg; (void)len;
}

int main(void) {
  Cap cc;
  cap_init(&cc);
  TimerConfig cfg = {.name = "stress"};
  void *ctx = my_timer_create(cfg, create_cb, &cc);
  cap_wait(&cc);
  if (!ctx) { fprintf(stderr, "create failed\n"); return 1; }

  pthread_t th[STRESS_THREADS];
  struct Args args[STRESS_THREADS];
  for (int i = 0; i < STRESS_THREADS; i++) {
    args[i].ctx = ctx;
    args[i].id = i;
    pthread_create(&th[i], NULL, worker, &args[i]);
  }
  for (int i = 0; i < STRESS_THREADS; i++) pthread_join(th[i], NULL);

  my_timer_destroy(ctx);
  cap_destroy(&cc);

  long ok = atomic_load(&g_ok), bad = atomic_load(&g_bad);
  long total = (long)STRESS_THREADS * STRESS_ITERS;
  printf("native+cbor stress: %ld/%ld ok, %ld bad (%d threads x %d iters)\n", ok,
         total, bad, STRESS_THREADS, STRESS_ITERS);
  printf(bad == 0 && ok == total ? "PASSED\n" : "FAILED\n");
  return (bad == 0 && ok == total) ? 0 : 1;
}
