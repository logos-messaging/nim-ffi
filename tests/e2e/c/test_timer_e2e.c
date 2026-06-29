/* End-to-end test for the generated C timer bindings. Exercises the same
 * surface as the C++ suite — constructor, sync + async methods, nested
 * seq/Option payloads, multi-parameter requests, the error channel and the
 * typed event listener — and aborts (non-zero exit) on the first failure so
 * ctest reports it. Plain assert is enough: there is no C unit framework
 * vendored, and each call is independently checkable. */
#include "my_timer.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int g_event_count = 0;
static char g_event_message[256];

static void on_echo_fired(const EchoEvent* evt, void* user_data) {
    int* hits = (int*)user_data;
    if (hits) {
        (*hits)++;
    }
    g_event_count = (int)evt->echoCount;
    snprintf(g_event_message, sizeof(g_event_message), "%s",
             evt->message.data ? evt->message.data : "");
}

static MyTimerCtx* make_ctx(void) {
    char* err = NULL;
    TimerConfig config = {nimffi_str("c-e2e")};
    MyTimerCtx* ctx = my_timer_ctx_create(&config, 30000, &err);
    if (!ctx) {
        fprintf(stderr, "create failed: %s\n", err ? err : "?");
        free(err);
    }
    assert(ctx != NULL);
    return ctx;
}

static void test_version(MyTimerCtx* ctx) {
    char* err = NULL;
    NimFfiStr version;
    assert(my_timer_ctx_version(ctx, &version, &err) == 0);
    assert(strcmp(version.data, "nim-timer v0.1.0") == 0);
    nimffi_free_str(&version);
}

static void test_echo(MyTimerCtx* ctx) {
    char* err = NULL;
    EchoRequest req = {nimffi_str("hello"), 10};
    EchoResponse resp;
    assert(my_timer_ctx_echo(ctx, &req, &resp, &err) == 0);
    assert(strcmp(resp.echoed.data, "hello") == 0);
    assert(strcmp(resp.timerName.data, "c-e2e") == 0);
    my_timer_free_EchoResponse(&resp);
}

static void test_complex(MyTimerCtx* ctx) {
    char* err = NULL;
    EchoRequest items[2] = {{nimffi_str("one"), 1}, {nimffi_str("two"), 2}};
    NimFfiStr tags[2] = {nimffi_str("a"), nimffi_str("b")};
    ComplexRequest req;
    req.messages.data = items;
    req.messages.len = 2;
    req.tags.data = tags;
    req.tags.len = 2;
    req.note.has_value = true;
    req.note.value = nimffi_str("note");
    req.retries.has_value = false;
    req.retries.value = 0;

    ComplexResponse resp;
    assert(my_timer_ctx_complex(ctx, &req, &resp, &err) == 0);
    assert(resp.itemCount == 2);
    assert(resp.hasNote == true);
    assert(strstr(resp.summary.data, "note=note") != NULL);
    my_timer_free_ComplexResponse(&resp);
}

static void test_schedule_ok(MyTimerCtx* ctx) {
    char* err = NULL;
    NimFfiStr payload[1] = {nimffi_str("p")};
    JobSpec job;
    job.name = nimffi_str("rollup");
    job.payload.data = payload;
    job.payload.len = 1;
    job.priority = 1;

    NimFfiStr retry_on[1] = {nimffi_str("timeout")};
    RetryPolicy retry;
    retry.maxAttempts = 3;
    retry.backoffMs = 100;
    retry.retryOn.data = retry_on;
    retry.retryOn.len = 1;

    ScheduleConfig sched;
    sched.startAtMs = 1000;
    sched.intervalMs = 0;
    sched.jitter.has_value = false;
    sched.jitter.value = 0;

    ScheduleResult res;
    assert(my_timer_ctx_schedule(ctx, &job, &retry, &sched, &res, &err) == 0);
    assert(strcmp(res.jobId.data, "c-e2e:rollup") == 0);
    assert(res.willRunCount == 1);
    my_timer_free_ScheduleResult(&res);
}

static void test_schedule_error(MyTimerCtx* ctx) {
    char* err = NULL;
    NimFfiStr payload[1] = {nimffi_str("p")};
    JobSpec job;
    job.name = nimffi_str(""); /* empty name → handler returns err */
    job.payload.data = payload;
    job.payload.len = 1;
    job.priority = 1;

    NimFfiStr retry_on[1] = {nimffi_str("timeout")};
    RetryPolicy retry;
    retry.maxAttempts = 3;
    retry.backoffMs = 100;
    retry.retryOn.data = retry_on;
    retry.retryOn.len = 1;

    ScheduleConfig sched;
    sched.startAtMs = 0;
    sched.intervalMs = 0;
    sched.jitter.has_value = false;
    sched.jitter.value = 0;

    ScheduleResult res;
    assert(my_timer_ctx_schedule(ctx, &job, &retry, &sched, &res, &err) != 0);
    assert(err != NULL);
    assert(strstr(err, "job name") != NULL);
    free(err);
}

static void test_event(MyTimerCtx* ctx) {
    char* err = NULL;
    int hits = 0;
    uint64_t handle =
        my_timer_ctx_add_on_echo_fired_listener(ctx, on_echo_fired, &hits);
    assert(handle != 0);

    EchoRequest req = {nimffi_str("evt"), 1};
    EchoResponse resp;
    assert(my_timer_ctx_echo(ctx, &req, &resp, &err) == 0);
    my_timer_free_EchoResponse(&resp);

    /* The event fires from the dispatch thread; poll briefly for delivery. */
    for (int i = 0; i < 100 && hits == 0; i++) {
        struct timespec t = {0, 10 * 1000 * 1000};
        nanosleep(&t, NULL);
    }
    assert(hits >= 1);
    assert(strcmp(g_event_message, "evt") == 0);
    assert(g_event_count == 1);

    assert(my_timer_ctx_remove_event_listener(ctx, handle) == true);
}

int main(void) {
    MyTimerCtx* ctx = make_ctx();
    test_version(ctx);
    test_echo(ctx);
    test_complex(ctx);
    test_schedule_ok(ctx);
    test_schedule_error(ctx);
    test_event(ctx);
    my_timer_ctx_destroy(ctx);
    printf("all C e2e checks passed\n");
    return 0;
}
