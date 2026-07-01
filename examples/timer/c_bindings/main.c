#include "my_timer.h"
#include <stdio.h>
#include <string.h>

#if defined(__STDC_NO_ATOMICS__)
#  error "C11 atomics required (or provide a mutex/condvar fallback)"
#endif
#include <stdatomic.h>

/* The `done` flags below are written from the library's dispatch thread and
 * polled from main, so they cross a thread boundary — atomics, not `volatile`,
 * give the visibility guarantee. sleep_ms wraps the platform nap so the demo
 * builds on Windows too. */
#if defined(_WIN32)
#  include <windows.h>
static void sleep_ms(unsigned ms) { Sleep(ms); }
#else
#  include <time.h>
static void sleep_ms(unsigned ms) {
    struct timespec t = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000 * 1000};
    nanosleep(&t, NULL);
}
#endif

/* The generated bindings are asynchronous: each call takes a result callback
 * and returns immediately. The reply and any error string handed to that
 * callback are owned by the binding and valid only while the callback runs —
 * the caller never frees them; it copies out whatever it wants to keep. This
 * demo turns each async call back into a sequential step by polling a `done`
 * flag (the same pattern the typed event listener already uses). */

/* Poll up to ~5s for a callback to fire. Returns false if it never did, so the
 * caller can report a stuck call instead of treating it as an empty success. */
static bool wait_done(atomic_int* done) {
    for (int i = 0; i < 500 && !atomic_load(done); i++) {
        sleep_ms(10);
    }
    return atomic_load(done) != 0;
}

static atomic_int g_echo_count = 0;
static char g_echo_message[256];

static void on_echo_fired(const EchoEvent* evt, void* user_data) {
    (void)user_data;
    atomic_store(&g_echo_count, (int)evt->echoCount);
    snprintf(g_echo_message, sizeof(g_echo_message), "%s",
             evt->message.data ? evt->message.data : "");
}

typedef struct {
    atomic_int done;
    int err_code;
    MyTimerCtx* ctx;
    char err[256];
} CreateWaiter;

static void on_created(int ec, MyTimerCtx* ctx, const char* em, void* ud) {
    CreateWaiter* w = (CreateWaiter*)ud;
    w->err_code = ec;
    w->ctx = ctx;
    if (em) snprintf(w->err, sizeof(w->err), "%s", em);
    atomic_store(&w->done, 1);
}

/* Generic reply sink: each step copies the fields it cares about out of its
 * typed reply into these slots (text_a/text_b for strings, num_a/num_b for
 * integers, flag for a boolean) before the binding reclaims the reply. */
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

static void on_version(int ec, const NimFfiStr* reply, const char* em, void* ud) {
    ReplyWaiter* w = (ReplyWaiter*)ud;
    w->err_code = ec;
    if (reply && reply->data) snprintf(w->text_a, sizeof(w->text_a), "%s", reply->data);
    if (em) snprintf(w->err, sizeof(w->err), "%s", em);
    atomic_store(&w->done, 1);
}

static void on_echo(int ec, const EchoResponse* reply, const char* em, void* ud) {
    ReplyWaiter* w = (ReplyWaiter*)ud;
    w->err_code = ec;
    if (reply) {
        if (reply->echoed.data)
            snprintf(w->text_a, sizeof(w->text_a), "%s", reply->echoed.data);
        if (reply->timerName.data)
            snprintf(w->text_b, sizeof(w->text_b), "%s", reply->timerName.data);
    }
    if (em) snprintf(w->err, sizeof(w->err), "%s", em);
    atomic_store(&w->done, 1);
}

static void on_complex(int ec, const ComplexResponse* reply, const char* em, void* ud) {
    ReplyWaiter* w = (ReplyWaiter*)ud;
    w->err_code = ec;
    if (reply) {
        w->num_a = (long long)reply->itemCount;
        w->flag = (int)reply->hasNote;
        if (reply->summary.data)
            snprintf(w->text_a, sizeof(w->text_a), "%s", reply->summary.data);
    }
    if (em) snprintf(w->err, sizeof(w->err), "%s", em);
    atomic_store(&w->done, 1);
}

static void on_schedule(int ec, const ScheduleResult* reply, const char* em, void* ud) {
    ReplyWaiter* w = (ReplyWaiter*)ud;
    w->err_code = ec;
    if (reply) {
        w->num_a = (long long)reply->willRunCount;
        w->num_b = (long long)reply->firstRunAtMs;
        if (reply->jobId.data)
            snprintf(w->text_a, sizeof(w->text_a), "%s", reply->jobId.data);
    }
    if (em) snprintf(w->err, sizeof(w->err), "%s", em);
    atomic_store(&w->done, 1);
}

/* Fire an async call, block until its callback lands, and bail to cleanup on a
 * timeout or error. Relies on `ctx` being in scope for that cleanup — these
 * steps all run against the one context created in main(). */
#define RUN(call, w)                                                  \
    do {                                                              \
        memset(&(w), 0, sizeof(w));                                   \
        call;                                                         \
        const char* run_err = NULL;                                   \
        if (!wait_done(&(w).done))                                    \
            run_err = "FFI call did not complete";                    \
        else if ((w).err_code != 0)                                   \
            run_err = (w).err[0] ? (w).err : "unknown";               \
        if (run_err) {                                                \
            fprintf(stderr, "Error: %s\n", run_err);                  \
            my_timer_ctx_destroy(ctx);                                \
            return 1;                                                 \
        }                                                             \
    } while (0)

int main(void) {
    CreateWaiter cw;
    memset(&cw, 0, sizeof(cw));
    TimerConfig config = {nimffi_str("c-demo")};
    my_timer_ctx_create(&config, on_created, &cw);
    if (!wait_done(&cw.done) || cw.err_code != 0 || !cw.ctx) {
        fprintf(stderr, "Error: %s\n",
                cw.err[0] ? cw.err : "create did not complete");
        return 1;
    }
    MyTimerCtx* ctx = cw.ctx;
    printf("[1] Context created\n");

    ReplyWaiter w;
    RUN(my_timer_ctx_version(ctx, on_version, &w), w);
    printf("[2] Version: %s\n", w.text_a);

    EchoRequest echo_req = {nimffi_str("hello from C"), 50};
    RUN(my_timer_ctx_echo(ctx, &echo_req, on_echo, &w), w);
    printf("[3] Echo: echoed=%s, timerName=%s\n", w.text_a, w.text_b);

    EchoRequest items[2] = {
        {nimffi_str("one"), 10},
        {nimffi_str("two"), 20},
    };
    NimFfiStr tags[2] = {nimffi_str("fast"), nimffi_str("c")};
    ComplexRequest complex_req;
    complex_req.messages.data = items;
    complex_req.messages.len = 2;
    complex_req.tags.data = tags;
    complex_req.tags.len = 2;
    complex_req.note.has_value = true;
    complex_req.note.value = nimffi_str("extra note");
    complex_req.retries.has_value = true;
    complex_req.retries.value = 3;

    RUN(my_timer_ctx_complex(ctx, &complex_req, on_complex, &w), w);
    printf("[4] Complex: summary=%s, itemCount=%lld, hasNote=%d\n", w.text_a, w.num_a,
           w.flag);

    NimFfiStr job_payload[2] = {nimffi_str("rollup"), nimffi_str("v2")};
    JobSpec job;
    job.name = nimffi_str("nightly-rollup");
    job.payload.data = job_payload;
    job.payload.len = 2;
    job.priority = 10;

    NimFfiStr retry_on[2] = {nimffi_str("timeout"), nimffi_str("5xx")};
    RetryPolicy retry;
    retry.maxAttempts = 3;
    retry.backoffMs = 500;
    retry.retryOn.data = retry_on;
    retry.retryOn.len = 2;

    ScheduleConfig schedule;
    schedule.startAtMs = 1000;
    schedule.intervalMs = 15000;
    schedule.jitter.has_value = true;
    schedule.jitter.value = 250;

    RUN(my_timer_ctx_schedule(ctx, &job, &retry, &schedule, on_schedule, &w), w);
    printf("[5] Schedule: jobId=%s, willRunCount=%lld, firstRunAtMs=%lld\n",
           w.text_a, w.num_a, w.num_b);

    uint64_t handle =
        my_timer_ctx_add_on_echo_fired_listener(ctx, on_echo_fired, NULL);
    EchoRequest evt_req = {nimffi_str("event-demo"), 1};
    memset(&w, 0, sizeof(w));
    my_timer_ctx_echo(ctx, &evt_req, on_echo, &w);
    wait_done(&w.done);
    /* The event fires from the library's dispatch thread; give it a moment. */
    sleep_ms(500);
    printf("[6] typed event onEchoFired: message=%s, echoCount=%d\n",
           g_echo_message, atomic_load(&g_echo_count));

    my_timer_ctx_remove_event_listener(ctx, handle);

    my_timer_ctx_destroy(ctx);
    printf("\nDone.\n");
    return 0;
}
