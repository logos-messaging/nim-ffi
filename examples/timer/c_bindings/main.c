#include "my_timer.h"
#include <stdio.h>
#include <string.h>

/* A sequential program. The library calls nothing back and the binding starts
 * no thread, so each step uses the `_sync` form of its request: it submits,
 * then dispatches the context until its own reply arrives, and hands every other
 * message that turns up meanwhile (an event, a liveness report) to the
 * handlers. What a `_sync` call returns belongs to the caller, who frees it.
 *
 * A program with a loop of its own uses the other form instead,
 * my_timer_ctx_<proc>(ctx, ..., on_reply, user_data), and calls
 * my_timer_ctx_dispatch_next() from that loop; step [7] shows it. */

#define TIMEOUT_MS 5000

typedef struct {
    int hits;
    long long echo_count;
    char message[256];
} EchoSink;

static void on_echo_fired(const EchoEvent* ev, void* user_data) {
    EchoSink* sink = (EchoSink*)user_data;
    sink->hits++;
    sink->echo_count = (long long)ev->echoCount;
    snprintf(sink->message, sizeof(sink->message), "%s", ev->message ? ev->message : "");
}

static void on_not_responding(uint64_t reason, void* user_data) {
    (void)user_data;
    fprintf(stderr, "library not responding (reason %llu)\n", (unsigned long long)reason);
}

typedef struct {
    int done;
    int ret;
    char echoed[256];
} AsyncEcho;

/* Runs inside my_timer_ctx_dispatch_next(). `reply` and `err` belong to the binding
 * and are gone once this returns: copy out what is worth keeping. */
static void on_echo(int ret, const EchoResponse* reply, const char* err, void* user_data) {
    AsyncEcho* a = (AsyncEcho*)user_data;
    a->ret = ret;
    if (reply && reply->echoed) snprintf(a->echoed, sizeof(a->echoed), "%s", reply->echoed);
    if (err) fprintf(stderr, "echo failed: %s\n", err);
    a->done = 1;
}

/* Reports a failed step. `err` is the text a `_sync` call handed out, or NULL. */
static int fail(MyTimerCtx* ctx, const char* step, int rc, char* err) {
    fprintf(stderr, "Error: %s returned %d: %s\n", step, rc, err ? err : "(no text)");
    free(err);
    my_timer_ctx_destroy(ctx);
    return 1;
}

int main(void) {
    char* err = NULL;
    int rc;

    TimerConfig config = {"c-demo"};
    MyTimerCtx* ctx = NULL;
    rc = my_timer_ctx_create_sync(&config, &ctx, &err, TIMEOUT_MS);
    if (rc != NIMFFI_RET_OK) return fail(NULL, "create", rc, err);
    printf("[1] Context created\n");

    /* Everything the library can send, besides replies, is an entry of
     * MyTimerHandlers; a NULL entry ignores that message. */
    EchoSink sink;
    memset(&sink, 0, sizeof(sink));
    MyTimerHandlers handlers;
    memset(&handlers, 0, sizeof(handlers));
    handlers.on_echo_fired = on_echo_fired;
    handlers.not_responding = on_not_responding;
    handlers.user_data = &sink;

    const char* version = NULL;
    rc = my_timer_ctx_version_sync(ctx, &version, &err, TIMEOUT_MS, &handlers);
    if (rc != NIMFFI_RET_OK) return fail(ctx, "version", rc, err);
    printf("[2] Version: %s\n", version);
    free((void*)version);

    printf("[2b] Header consts: TIMER_VERSION=%s, MAX_DELAY_MS=%lld\n", TIMER_VERSION,
           (long long)MAX_DELAY_MS);

    /* This request fires on_echo_fired before it answers, so the handler runs
     * inside the `_sync` call. */
    EchoRequest echo_req = {"hello from C", 50};
    EchoResponse echo_res;
    rc = my_timer_ctx_echo_sync(ctx, &echo_req, &echo_res, &err, TIMEOUT_MS, &handlers);
    if (rc != NIMFFI_RET_OK) return fail(ctx, "echo", rc, err);
    printf("[3] Echo: echoed=%s, timerName=%s\n", echo_res.echoed, echo_res.timerName);
    my_timer_free_EchoResponse(&echo_res);
    printf("[3b] typed event onEchoFired: message=%s, echoCount=%lld\n", sink.message,
           sink.echo_count);

    EchoRequest items[2] = {
        {"one", 10},
        {"two", 20},
    };
    const char* tags[2] = {"fast", "c"};
    ComplexRequest complex_req;
    complex_req.messages.data = items;
    complex_req.messages.len = 2;
    complex_req.tags.data = tags;
    complex_req.tags.len = 2;
    complex_req.note.has_value = true;
    complex_req.note.value = "extra note";
    complex_req.retries.has_value = true;
    complex_req.retries.value = 3;

    ComplexResponse complex_res;
    rc = my_timer_ctx_complex_sync(ctx, &complex_req, &complex_res, &err, TIMEOUT_MS, &handlers);
    if (rc != NIMFFI_RET_OK) return fail(ctx, "complex", rc, err);
    printf("[4] Complex: summary=%s, itemCount=%lld, hasNote=%d\n", complex_res.summary,
           (long long)complex_res.itemCount, (int)complex_res.hasNote);
    my_timer_free_ComplexResponse(&complex_res);

    const char* job_payload[2] = {"rollup", "v2"};
    JobSpec job;
    job.name = "nightly-rollup";
    job.payload.data = job_payload;
    job.payload.len = 2;
    job.priority = JOB_PRIORITY_JP_HIGH;

    const char* retry_on[2] = {"timeout", "5xx"};
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

    ScheduleResult sched_res;
    rc = my_timer_ctx_schedule_sync(ctx, &job, &retry, &schedule, &sched_res, &err, TIMEOUT_MS,
                                    &handlers);
    if (rc != NIMFFI_RET_OK) return fail(ctx, "schedule", rc, err);
    printf("[5] Schedule: jobId=%s, willRunCount=%lld, effectiveBackoffMs=%lld, "
           "priority=%d\n",
           sched_res.jobId, (long long)sched_res.willRunCount,
           (long long)sched_res.effectiveBackoffMs, (int)sched_res.priority);
    my_timer_free_ScheduleResult(&sched_res);

    /* A request the library answers with an error: the code says so, `err` says why. */
    EchoRequest bad_req = {"too slow", MAX_DELAY_MS + 1};
    rc = my_timer_ctx_echo_sync(ctx, &bad_req, &echo_res, &err, TIMEOUT_MS, &handlers);
    printf("[6] Echo over the limit: ret=%d, err=%s\n", rc, err ? err : "(none)");
    free(err);
    err = NULL;

    /* The other shape, for a program with a loop: submit, then dispatch. on_echo
     * runs inside the dispatch loop, on this thread. */
    AsyncEcho async_echo;
    memset(&async_echo, 0, sizeof(async_echo));
    EchoRequest async_req = {"async from C", 1};
    rc = my_timer_ctx_echo(ctx, &async_req, on_echo, &async_echo, NULL);
    if (rc != NIMFFI_RET_OK) {
        fprintf(stderr, "Error: echo was refused (%d): %s\n", rc, my_timer_last_error());
        my_timer_ctx_destroy(ctx);
        return 1;
    }
    for (int i = 0; i < 50 && !async_echo.done; i++) {
        /* Each turn waits up to 100ms for one message and dispatches it. */
        rc = my_timer_ctx_dispatch_next(ctx, 100, &handlers);
        if (rc != NIMFFI_RET_OK && rc != NIMFFI_RET_TIMEOUT) {
            fprintf(stderr, "Error: dispatch returned %d\n", rc);
            break;
        }
    }
    printf("[7] Async echo: ret=%d, echoed=%s (events so far: %d)\n", async_echo.ret,
           async_echo.echoed, sink.hits);

    /* A static request needs no context; its reply comes on the static one. */
    const char* lib_version = NULL;
    rc = my_timer_static_lib_version_sync(&lib_version, &err, TIMEOUT_MS, NULL);
    if (rc != NIMFFI_RET_OK) return fail(ctx, "lib_version", rc, err);
    printf("[8] Static lib version: %s\n", lib_version);
    free((void*)lib_version);

    my_timer_ctx_destroy(ctx);
    my_timer_shutdown();
    printf("\nDone.\n");
    return 0;
}
