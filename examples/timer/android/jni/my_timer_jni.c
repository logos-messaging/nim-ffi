// JNI bridge: exposes the timer library's native C ABI to Kotlin/Java.
//
// The library calls back on its own FFI thread; each bridge function blocks on a
// condvar until the callback fires, then returns a plain Java value — so the
// Kotlin side sees a simple synchronous API. A struct return (EchoResponse) is
// read out of the typed C-POD inside the callback (valid only there).
#include "my_timer.h"

#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  int ret, done;
  char text[1024];   // string return / error text
  char echoed[256];  // EchoResponse.echoed
  char timerName[256];
  pthread_mutex_t mu;
  pthread_cond_t cv;
} Resp;

static void resp_init(Resp *r) {
  memset(r, 0, sizeof(*r));
  pthread_mutex_init(&r->mu, NULL);
  pthread_cond_init(&r->cv, NULL);
}
static void resp_destroy(Resp *r) {
  pthread_mutex_destroy(&r->mu);
  pthread_cond_destroy(&r->cv);
}
static void resp_wait(Resp *r) {
  pthread_mutex_lock(&r->mu);
  while (!r->done) pthread_cond_wait(&r->cv, &r->mu);
  pthread_mutex_unlock(&r->mu);
}

static void copy_raw(char *dst, size_t cap, const char *msg, size_t len) {
  size_t n = len < cap - 1 ? len : cap - 1;
  if (msg && n) memcpy(dst, msg, n);
  dst[n] = '\0';
}

static void ack_cb(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  if (ret == RET_ERR) copy_raw(r->text, sizeof(r->text), msg, len);
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}
static void string_cb(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  copy_raw(r->text, sizeof(r->text), msg, len);
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}
static void echo_cb(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  if (ret == RET_OK) {
    const EchoResponse *e = (const EchoResponse *)msg; // typed struct return
    strncpy(r->echoed, e->echoed, sizeof(r->echoed) - 1);
    strncpy(r->timerName, e->timerName, sizeof(r->timerName) - 1);
  } else {
    copy_raw(r->text, sizeof(r->text), msg, len);
  }
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}

JNIEXPORT jlong JNICALL
Java_org_logos_mytimer_TimerNode_nativeCreate(JNIEnv *env, jobject thiz,
                                              jstring jname) {
  const char *name = (*env)->GetStringUTFChars(env, jname, NULL);
  Resp r;
  resp_init(&r);
  TimerConfig cfg = {.name = name};
  void *ctx = my_timer_create(cfg, ack_cb, &r);
  resp_wait(&r);
  (*env)->ReleaseStringUTFChars(env, jname, name);
  resp_destroy(&r);
  (void)thiz;
  return (jlong)(intptr_t)ctx;
}

JNIEXPORT jstring JNICALL
Java_org_logos_mytimer_TimerNode_nativeVersion(JNIEnv *env, jobject thiz,
                                               jlong ctx) {
  Resp r;
  resp_init(&r);
  if (my_timer_version((void *)(intptr_t)ctx, string_cb, &r) == RET_OK)
    resp_wait(&r);
  jstring out = (*env)->NewStringUTF(env, r.text);
  resp_destroy(&r);
  (void)thiz;
  return out;
}

// Returns String[2] = { echoed, timerName }.
JNIEXPORT jobjectArray JNICALL
Java_org_logos_mytimer_TimerNode_nativeEcho(JNIEnv *env, jobject thiz, jlong ctx,
                                            jstring jmsg, jlong delayMs) {
  const char *msg = (*env)->GetStringUTFChars(env, jmsg, NULL);
  Resp r;
  resp_init(&r);
  EchoRequest req = {.message = msg, .delayMs = (int64_t)delayMs};
  if (my_timer_echo((void *)(intptr_t)ctx, echo_cb, &r, req) == RET_OK)
    resp_wait(&r);
  (*env)->ReleaseStringUTFChars(env, jmsg, msg);

  jclass strClass = (*env)->FindClass(env, "java/lang/String");
  jobjectArray arr = (*env)->NewObjectArray(env, 2, strClass, NULL);
  (*env)->SetObjectArrayElement(env, arr, 0, (*env)->NewStringUTF(env, r.echoed));
  (*env)->SetObjectArrayElement(env, arr, 1, (*env)->NewStringUTF(env, r.timerName));
  resp_destroy(&r);
  (void)thiz;
  return arr;
}

JNIEXPORT void JNICALL
Java_org_logos_mytimer_TimerNode_nativeDestroy(JNIEnv *env, jobject thiz,
                                               jlong ctx) {
  my_timer_destroy((void *)(intptr_t)ctx);
  (void)env;
  (void)thiz;
}
