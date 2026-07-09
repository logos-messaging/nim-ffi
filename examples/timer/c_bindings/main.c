#include "my_timer.h"
#include <stdio.h>
#include <string.h>

/* Uses the generated blocking `_sync` API: each call submits, waits up to
 * `timeout_ms`, deep-copies the reply into a caller-owned out-param (released
 * with the generated <lib>_free_<Type>() helper) and returns 0, or fills `err`
 * and returns non-zero — no hand-rolled waiters. Events still arrive async on
 * the dispatch thread, so the typed listener records into globals below. */

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

#define TIMEOUT_MS 5000

static int g_echo_count;
static char g_echo_message[256];

static void on_echo_fired(const EchoEvent* evt, void* user_data) {
    (void)user_data;
    g_echo_count = (int)evt->echoCount;
    snprintf(g_echo_message, sizeof(g_echo_message), "%s",
             evt->message.data ? evt->message.data : "");
}

/* Run a blocking `_sync` call; on failure print the error it wrote into `err`,
 * tear the context down and bail. `ctx` and `err` are in scope in main(). */
#define RUN(call)                                        \
    do {                                                 \
        if ((call) != 0) {                               \
            fprintf(stderr, "Error: %s\n", err);         \
            my_timer_ctx_destroy(ctx);                   \
            return 1;                                     \
        }                                                \
    } while (0)

int main(void) {
    char err[256] = {0};
    MyTimerCtx* ctx = NULL;
    TimerConfig config = {nimffi_str("c-demo")};
    if (my_timer_ctx_create_sync(&config, &ctx, err, sizeof(err), TIMEOUT_MS) != 0) {
        fprintf(stderr, "Error: %s\n", err);
        return 1;
    }
    printf("[1] Context created\n");

    NimFfiStr version = {0};
    RUN(my_timer_ctx_version_sync(ctx, &version, err, sizeof(err), TIMEOUT_MS));
    printf("[2] Version: %s\n", version.data ? version.data : "");
    nimffi_free_str(&version);

    EchoRequest echo_req = {nimffi_str("hello from C"), 50};
    EchoResponse echo = {0};
    RUN(my_timer_ctx_echo_sync(ctx, &echo_req, &echo, err, sizeof(err), TIMEOUT_MS));
    printf("[3] Echo: echoed=%s, timerName=%s\n", echo.echoed.data, echo.timerName.data);
    my_timer_free_EchoResponse(&echo);

    EchoRequest items[2] = {{nimffi_str("one"), 10}, {nimffi_str("two"), 20}};
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

    ComplexResponse complex = {0};
    RUN(my_timer_ctx_complex_sync(ctx, &complex_req, &complex, err, sizeof(err),
                                  TIMEOUT_MS));
    printf("[4] Complex: summary=%s, itemCount=%lld, hasNote=%d\n", complex.summary.data,
           (long long)complex.itemCount, (int)complex.hasNote);
    my_timer_free_ComplexResponse(&complex);

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

    ScheduleResult sched = {0};
    RUN(my_timer_ctx_schedule_sync(ctx, &job, &retry, &schedule, &sched, err,
                                   sizeof(err), TIMEOUT_MS));
    printf("[5] Schedule: jobId=%s, willRunCount=%lld, firstRunAtMs=%lld\n",
           sched.jobId.data, (long long)sched.willRunCount,
           (long long)sched.firstRunAtMs);
    my_timer_free_ScheduleResult(&sched);

    uint64_t handle = my_timer_ctx_add_on_echo_fired_listener(ctx, on_echo_fired, NULL);
    EchoRequest evt_req = {nimffi_str("event-demo"), 1};
    EchoResponse evt_echo = {0};
    RUN(my_timer_ctx_echo_sync(ctx, &evt_req, &evt_echo, err, sizeof(err), TIMEOUT_MS));
    my_timer_free_EchoResponse(&evt_echo);
    /* The event fires from the library's dispatch thread; give it a moment. */
    sleep_ms(500);
    printf("[6] typed event onEchoFired: message=%s, echoCount=%d\n", g_echo_message,
           g_echo_count);
    my_timer_ctx_remove_event_listener(ctx, handle);

    my_timer_ctx_destroy(ctx);
    printf("\nDone.\n");
    return 0;
}
