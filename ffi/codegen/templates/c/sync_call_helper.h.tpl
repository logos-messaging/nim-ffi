#ifndef NIM_FFI_SYNC_CALL_HELPER_H_INCLUDED
#define NIM_FFI_SYNC_CALL_HELPER_H_INCLUDED
/* Blocking request/response helper. The Nim side delivers the result through
 * an FFICallback that may fire from another thread — and, on a timeout, may
 * fire *after* the caller has given up. The call state is therefore reference
 * counted (one ref for the caller, one for the pending callback); whichever
 * side runs last frees it, so a late callback can never write into freed
 * memory. Mirrors the C++ binding's shared_ptr-guarded ffi_call_. */

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);

typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t cv;
    int refs;
    bool done;
    bool ok;
    uint8_t* bytes;
    size_t len;
    char* err; /* heap C string on failure */
} NimFfiCallState;

static inline NimFfiCallState* nimffi_state_new(void) {
    NimFfiCallState* s = (NimFfiCallState*)calloc(1, sizeof(NimFfiCallState));
    if (!s) {
        return NULL;
    }
    pthread_mutex_init(&s->mtx, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->refs = 2;
    return s;
}

static inline void nimffi_state_unref(NimFfiCallState* s) {
    pthread_mutex_lock(&s->mtx);
    int remaining = --s->refs;
    pthread_mutex_unlock(&s->mtx);
    if (remaining != 0) {
        return;
    }
    pthread_mutex_destroy(&s->mtx);
    pthread_cond_destroy(&s->cv);
    free(s->bytes);
    free(s->err);
    free(s);
}

/* The single FFICallback shared by every blocking call. `user_data` is the
 * NimFfiCallState*; this consumes the callback's reference on every path. */
static inline void nimffi_on_result(
        int ret, const char* msg, size_t len, void* user_data) {
    NimFfiCallState* s = (NimFfiCallState*)user_data;
    pthread_mutex_lock(&s->mtx);
    s->ok = (ret == 0);
    if (msg && len > 0) {
        if (s->ok) {
            s->bytes = (uint8_t*)malloc(len);
            if (s->bytes) {
                memcpy(s->bytes, msg, len);
                s->len = len;
            }
        } else {
            s->err = (char*)malloc(len + 1);
            if (s->err) {
                memcpy(s->err, msg, len);
                s->err[len] = '\0';
            }
        }
    }
    s->done = true;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mtx);
    nimffi_state_unref(s);
}

/* RET_MISSING_CALLBACK from the Nim dispatcher: the callback will never fire,
 * so the request path must reclaim the callback's reference itself. */
#define NIMFFI_RET_MISSING_CALLBACK 2

/* Wait up to timeout_ms for nimffi_on_result to fire on `s`, then hand the
 * success payload back through out_bytes / out_len and drop the caller's
 * reference. Returns 0 on success; -1 and *err (heap) on failure/timeout.
 * The matching state was created by nimffi_state_new() (refs == 2): the
 * callback owns the other reference and frees the state if it fires late. */
static inline int nimffi_wait_result(
        NimFfiCallState* s, uint32_t timeout_ms,
        uint8_t** out_bytes, size_t* out_len, char** err) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(timeout_ms / 1000u);
    deadline.tv_nsec += (long)(timeout_ms % 1000u) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }

    int rc = 0;
    pthread_mutex_lock(&s->mtx);
    while (!s->done && rc == 0) {
        rc = pthread_cond_timedwait(&s->cv, &s->mtx, &deadline);
    }
    bool done = s->done;
    bool ok = s->ok;
    uint8_t* bytes = s->bytes;
    size_t blen = s->len;
    char* emsg = s->err;
    if (done && ok) {
        s->bytes = NULL; /* ownership transferred to caller */
        s->len = 0;
    } else if (done) {
        s->err = NULL;
    }
    pthread_mutex_unlock(&s->mtx);

    int status;
    if (!done) {
        if (err) *err = nimffi_dup_cstr("FFI call timed out");
        status = -1;
    } else if (!ok) {
        if (err) *err = emsg ? emsg : nimffi_dup_cstr("FFI call failed");
        status = -1;
    } else {
        *out_bytes = bytes;
        *out_len = blen;
        status = 0;
    }

    nimffi_state_unref(s);
    return status;
}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_SYNC_CALL_HELPER_H_INCLUDED */
