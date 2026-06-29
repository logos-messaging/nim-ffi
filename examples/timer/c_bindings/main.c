#include "my_timer.h"
#include <stdio.h>

/* The generated bindings never throw and never longjmp: every call returns a
 * status int and, on failure, a heap `char* err` the caller frees. Response
 * values returned through an out-parameter are owned by the caller and freed
 * with the generated my_timer_free_<Type>() helpers. */

static volatile int g_echo_count = 0;
static char g_echo_message[256];

static void on_echo_fired(const EchoEvent* evt, void* user_data) {
    (void)user_data;
    g_echo_count = (int)evt->echoCount;
    snprintf(g_echo_message, sizeof(g_echo_message), "%s",
             evt->message.data ? evt->message.data : "");
}

int main(void) {
    char* err = NULL;

    TimerConfig config = {nimffi_str("c-demo")};
    MyTimerCtx* ctx = my_timer_ctx_create(&config, 30000, &err);
    if (!ctx) {
        fprintf(stderr, "Error: %s\n", err ? err : "unknown");
        free(err);
        return 1;
    }
    printf("[1] Context created\n");

    NimFfiStr version;
    if (my_timer_ctx_version(ctx, &version, &err) != 0) {
        fprintf(stderr, "Error: %s\n", err ? err : "unknown");
        free(err);
        my_timer_ctx_destroy(ctx);
        return 1;
    }
    printf("[2] Version: %s\n", version.data);
    nimffi_free_str(&version);

    EchoRequest echo_req = {nimffi_str("hello from C"), 50};
    EchoResponse echo_resp;
    if (my_timer_ctx_echo(ctx, &echo_req, &echo_resp, &err) != 0) {
        fprintf(stderr, "Error: %s\n", err ? err : "unknown");
        free(err);
        my_timer_ctx_destroy(ctx);
        return 1;
    }
    printf("[3] Echo: echoed=%s, timerName=%s\n",
           echo_resp.echoed.data, echo_resp.timerName.data);
    my_timer_free_EchoResponse(&echo_resp);

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

    ComplexResponse complex_resp;
    if (my_timer_ctx_complex(ctx, &complex_req, &complex_resp, &err) != 0) {
        fprintf(stderr, "Error: %s\n", err ? err : "unknown");
        free(err);
        my_timer_ctx_destroy(ctx);
        return 1;
    }
    printf("[4] Complex: summary=%s, itemCount=%lld, hasNote=%d\n",
           complex_resp.summary.data,
           (long long)complex_resp.itemCount,
           (int)complex_resp.hasNote);
    my_timer_free_ComplexResponse(&complex_resp);

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

    ScheduleResult schedule_res;
    if (my_timer_ctx_schedule(ctx, &job, &retry, &schedule, &schedule_res, &err) != 0) {
        fprintf(stderr, "Error: %s\n", err ? err : "unknown");
        free(err);
        my_timer_ctx_destroy(ctx);
        return 1;
    }
    printf("[5] Schedule: jobId=%s, willRunCount=%lld, firstRunAtMs=%lld\n",
           schedule_res.jobId.data,
           (long long)schedule_res.willRunCount,
           (long long)schedule_res.firstRunAtMs);
    my_timer_free_ScheduleResult(&schedule_res);

    uint64_t handle =
        my_timer_ctx_add_on_echo_fired_listener(ctx, on_echo_fired, NULL);
    EchoRequest evt_req = {nimffi_str("event-demo"), 1};
    EchoResponse evt_resp;
    if (my_timer_ctx_echo(ctx, &evt_req, &evt_resp, &err) == 0) {
        my_timer_free_EchoResponse(&evt_resp);
    } else {
        free(err);
        err = NULL;
    }
    /* The event fires from the library's dispatch thread; give it a moment. */
    struct timespec settle = {0, 100 * 1000 * 1000};
    nanosleep(&settle, NULL);
    printf("[6] typed event onEchoFired: message=%s, echoCount=%d\n",
           g_echo_message, g_echo_count);

    my_timer_ctx_remove_event_listener(ctx, handle);

    my_timer_ctx_destroy(ctx);
    printf("\nDone.\n");
    return 0;
}
