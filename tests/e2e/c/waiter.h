#ifndef NIM_FFI_E2E_WAITER_H_INCLUDED
#define NIM_FFI_E2E_WAITER_H_INCLUDED
/* Turns an async binding call into a sequential check. Include after the generated binding header, which defines NimFfiStr. */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#if defined(__STDC_NO_ATOMICS__)
#  error "C11 atomics required (or provide a mutex/condvar fallback)"
#endif
#include <stdatomic.h>

#if defined(_WIN32)
/* Keep windows.h from defining min/max and the bulk of the SDK macro surface. */
#  define WIN32_LEAN_AND_MEAN
#  define NOMINMAX
#  include <windows.h>
static inline void sleep_ms(unsigned ms) { Sleep(ms); }
#else
#  include <time.h>
static inline void sleep_ms(unsigned ms) {
    struct timespec t = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000 * 1000};
    nanosleep(&t, NULL);
}
#endif

/* Acquiring `done` publishes the fields the callback wrote first; a plain `volatile` orders nothing and TSan calls the read a race. */
static inline void wait_done(atomic_int* done) {
    for (int i = 0; i < 500 && !atomic_load_explicit(done, memory_order_acquire); i++) {
        sleep_ms(10);
    }
    assert(atomic_load_explicit(done, memory_order_acquire));
}

/* `ctx` is void* because each library has its own context type. */
typedef struct {
    atomic_int done;
    int err_code;
    void* ctx;
    char err[256];
} CreateWaiter;

typedef struct {
    atomic_int done;
    int err_code;
    char err[256];
    char text_a[256];
    char text_b[256];
    long long num_a;
    long long num_b;
    int flag;
} ReplyWaiter;

static inline void waiter_copy_err(char* dst, size_t cap, const char* em) {
    if (em) {
        snprintf(dst, cap, "%s", em);
    }
}

static inline void waiter_finish(atomic_int* done) {
    atomic_store_explicit(done, 1, memory_order_release);
}

/* Shared terminal callback for any proc returning a bare string. */
static inline void on_str(int ec, const NimFfiStr* reply, const char* em, void* ud) {
    ReplyWaiter* w = (ReplyWaiter*)ud;
    w->err_code = ec;
    if (reply && reply->data) {
        snprintf(w->text_a, sizeof(w->text_a), "%s", reply->data);
    }
    waiter_copy_err(w->err, sizeof(w->err), em);
    waiter_finish(&w->done);
}

#endif /* NIM_FFI_E2E_WAITER_H_INCLUDED */
