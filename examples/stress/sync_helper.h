/* Tiny condvar-based "wait until callback fires" helper shared by every
 * stress scenario. Kept in one place so the test bodies stay focused on
 * what's actually being exercised. */

#ifndef NIM_FFI_STRESS_SYNC_HELPER_H
#define NIM_FFI_STRESS_SYNC_HELPER_H

#include <pthread.h>
#include <string.h>
#include <stdlib.h>

/* Sync primitives. Each scenario writes its own callbacks that deep-copy
 * whatever response fields it cares about (strings/arrays inside the
 * wire Resp are only valid during the callback invocation), then call
 * `ffi_sync_signal()` at the end. */

typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t  cv;
    int             done;
    int             ret;
    char            err[256];
    /* generic scratch slots scenarios may use */
    long            slot_int_a;
    long            slot_int_b;
    char            slot_str_a[256];
    char            slot_str_b[256];
} ffi_sync_t;

static inline void ffi_sync_init(ffi_sync_t* s) {
    pthread_mutex_init(&s->mtx, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->done = 0;
    s->ret = -1;
    s->err[0] = s->slot_str_a[0] = s->slot_str_b[0] = '\0';
    s->slot_int_a = s->slot_int_b = -1;
}

static inline void ffi_sync_destroy(ffi_sync_t* s) {
    pthread_cond_destroy(&s->cv);
    pthread_mutex_destroy(&s->mtx);
}

static inline void ffi_sync_wait(ffi_sync_t* s) {
    pthread_mutex_lock(&s->mtx);
    while (!s->done) pthread_cond_wait(&s->cv, &s->mtx);
    pthread_mutex_unlock(&s->mtx);
}

static inline void ffi_sync_signal(ffi_sync_t* s) {
    pthread_mutex_lock(&s->mtx);
    s->done = 1;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mtx);
}

static inline void ffi_sync_capture_err(ffi_sync_t* s, const char* msg, size_t len) {
    if (!msg || len == 0) return;
    size_t n = len < sizeof(s->err) - 1 ? len : sizeof(s->err) - 1;
    memcpy(s->err, msg, n);
    s->err[n] = '\0';
}

static inline void ffi_sync_copy_str(char* dst, size_t cap, const char* src) {
    if (!src) { dst[0] = '\0'; return; }
    strncpy(dst, src, cap - 1);
    dst[cap - 1] = '\0';
}

#endif /* NIM_FFI_STRESS_SYNC_HELPER_H */
