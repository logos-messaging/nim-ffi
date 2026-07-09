#ifndef NIM_FFI_SYNC_HELPER_H_INCLUDED
#define NIM_FFI_SYNC_HELPER_H_INCLUDED
/* Blocking-call helper shared by the generated <lib>_ctx_<method>_sync wrappers.
 * Turns the async callback ABI into a synchronous request/reply: submit the
 * call, block on a condition variable until its single callback fires (or the
 * timeout elapses), then hand the raw CBOR payload / error text back so the
 * generated wrapper can decode it into a caller-owned out-param.
 *
 * The state is heap-allocated and reference-counted (2: the waiter and the
 * callback). A callback that fires after the caller has already timed out thus
 * writes into a still-live object and drops the last reference cleanly — no
 * use-after-free, no leak. Uses pthreads on POSIX and SRWLOCK/CONDITION_VARIABLE
 * on Win32, the same platform split the example programs use. */
#include "nim_ffi_cbor.h"

#if defined(_WIN32)
#  include <windows.h>
#else
#  include <pthread.h>
#  include <errno.h>
#  include <time.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
#if defined(_WIN32)
    SRWLOCK            lock;
    CONDITION_VARIABLE cv;
#else
    pthread_mutex_t    mtx;
    pthread_cond_t     cv;
#endif
    int      done;
    int      ok;
    int      ret_code;   /* raw `ret` from the callback (non-zero on error) */
    uint8_t* bytes;      /* owned copy of the CBOR reply payload on success */
    size_t   bytes_len;
    char*    err;        /* owned NUL-terminated error text on failure */
    int      refs;       /* guarded by lock/mtx; the release reaching 0 frees */
} NimFfiSyncState;

static inline NimFfiSyncState* nimffi_sync_state_new(void) {
    NimFfiSyncState* s = (NimFfiSyncState*)calloc(1, sizeof(NimFfiSyncState));
    if (!s) {
        return NULL;
    }
    s->refs = 2;
#if defined(_WIN32)
    InitializeSRWLock(&s->lock);
    InitializeConditionVariable(&s->cv);
#else
    if (pthread_mutex_init(&s->mtx, NULL) != 0) {
        free(s);
        return NULL;
    }
    if (pthread_cond_init(&s->cv, NULL) != 0) {
        pthread_mutex_destroy(&s->mtx);
        free(s);
        return NULL;
    }
#endif
    return s;
}

static inline void nimffi_sync_state_release(NimFfiSyncState* s) {
    if (!s) {
        return;
    }
    int r;
#if defined(_WIN32)
    AcquireSRWLockExclusive(&s->lock);
    r = --s->refs;
    ReleaseSRWLockExclusive(&s->lock);
#else
    pthread_mutex_lock(&s->mtx);
    r = --s->refs;
    pthread_mutex_unlock(&s->mtx);
#endif
    if (r != 0) {
        return;
    }
#if !defined(_WIN32)
    pthread_mutex_destroy(&s->mtx);
    pthread_cond_destroy(&s->cv);
#endif
    free(s->bytes);
    free(s->err);
    free(s);
}

/* FFICallback-conforming sink: copies the reply/error out of the borrowed
 * msg/len buffer (owned by the binding only for this call), wakes the waiter,
 * then drops the callback's reference. */
static inline void nimffi_sync_cb(int ret, const char* msg, size_t len, void* ud) {
    NimFfiSyncState* s = (NimFfiSyncState*)ud;
#if defined(_WIN32)
    AcquireSRWLockExclusive(&s->lock);
#else
    pthread_mutex_lock(&s->mtx);
#endif
    s->ret_code = ret;
    s->ok = (ret == 0);
    if (msg && len > 0) {
        if (s->ok) {
            uint8_t* p = (uint8_t*)malloc(len);
            if (p) {
                memcpy(p, msg, len);
                s->bytes = p;
                s->bytes_len = len;
            }
        } else {
            s->err = nimffi_dup_cstr_n(msg, len);
        }
    }
    s->done = 1;
#if defined(_WIN32)
    WakeConditionVariable(&s->cv);
    ReleaseSRWLockExclusive(&s->lock);
#else
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mtx);
#endif
    nimffi_sync_state_release(s);
}

/* Blocks until the callback marks the state done or `timeout_ms` elapses.
 * Returns 1 if the reply landed, 0 on timeout. The deadline is absolute so a
 * spurious wakeup cannot extend the wait past the requested budget. */
static inline int nimffi_sync_wait(NimFfiSyncState* s, uint32_t timeout_ms) {
    int done;
#if defined(_WIN32)
    ULONGLONG start = GetTickCount64();
    AcquireSRWLockExclusive(&s->lock);
    while (!s->done) {
        ULONGLONG elapsed = GetTickCount64() - start;
        if (elapsed >= timeout_ms) {
            break;
        }
        if (!SleepConditionVariableSRW(&s->cv, &s->lock,
                                       (DWORD)(timeout_ms - elapsed), 0)) {
            if (GetLastError() == ERROR_TIMEOUT) {
                break;
            }
        }
    }
    done = s->done;
    ReleaseSRWLockExclusive(&s->lock);
#else
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(timeout_ms / 1000u);
    deadline.tv_nsec += (long)(timeout_ms % 1000u) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }
    pthread_mutex_lock(&s->mtx);
    while (!s->done) {
        if (pthread_cond_timedwait(&s->cv, &s->mtx, &deadline) == ETIMEDOUT) {
            break;
        }
    }
    done = s->done;
    pthread_mutex_unlock(&s->mtx);
#endif
    return done;
}

/* Bounded copy of `src` into `buf`, always NUL-terminating when err_len > 0. */
static inline void nimffi_copy_err(char* buf, size_t err_len, const char* src) {
    if (!buf || err_len == 0) {
        return;
    }
    if (!src) {
        src = "";
    }
    size_t n = strlen(src);
    if (n >= err_len) {
        n = err_len - 1;
    }
    memcpy(buf, src, n);
    buf[n] = '\0';
}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_SYNC_HELPER_H_INCLUDED */

