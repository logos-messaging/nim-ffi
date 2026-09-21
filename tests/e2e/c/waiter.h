#ifndef NIM_FFI_E2E_WAITER_H_INCLUDED
#define NIM_FFI_E2E_WAITER_H_INCLUDED
/* Turns an asynchronous binding call into a sequential check. Include after the generated binding header, which defines the request/reply types. */
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* Long enough for a loaded CI machine; a healthy run never gets near it. */
#define WAIT_LIMIT_MS 5000

/* Callbacks run inside the dispatch loop, on the thread that waits: plain fields, no atomics. */
typedef struct {
    int done;
    int ret;
    char err[256];
} CreateWaiter;

typedef struct {
    int done;
    int ret;
    char err[256];
    char text_a[256];
    char text_b[256];
    long long num_a;
    long long num_b;
    int flag;
} ReplyWaiter;

static inline void waiter_settle(int* done, char* err, size_t cap, const char* err_msg) {
    if (err_msg) {
        snprintf(err, cap, "%s", err_msg);
    }
    (*done)++;
}

/* Dispatches with `dispatcher_call` (an expression returning the dispatch loop’s code) until `done`
 * is set. A -1 is a message that did not dispatch, which no test here expects. */
#define WAIT_DONE(done, dispatcher_call)                                        \
    do {                                                                  \
        int64_t wait_deadline_ = nimffi_now_ms() + WAIT_LIMIT_MS;         \
        while (!(done) && nimffi_now_ms() < wait_deadline_) {             \
            int wait_rc_ = (dispatcher_call);                                   \
            assert(wait_rc_ == NIMFFI_RET_OK || wait_rc_ == NIMFFI_RET_TIMEOUT); \
        }                                                                 \
        assert(done);                                                     \
    } while (0)

static inline void on_created(int ret, const char* err_msg, void* user_data) {
    CreateWaiter* w = (CreateWaiter*)user_data;
    w->ret = ret;
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

/* Shared reply callback for any proc returning a bare string. */
static inline void on_str(int ret, const char* const* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->ret = ret;
    if (reply && *reply) {
        snprintf(w->text_a, sizeof(w->text_a), "%s", *reply);
    }
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

#endif /* NIM_FFI_E2E_WAITER_H_INCLUDED */
