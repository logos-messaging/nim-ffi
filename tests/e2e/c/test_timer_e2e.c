/* End-to-end test for the generated C timer bindings. Exercises the same
 * surface as the C++ suite — constructor, methods, nested seq/Option payloads,
 * multi-parameter requests, the error channel and the typed event listener —
 * and aborts (non-zero exit) on the first failure so ctest reports it.
 *
 * The binding is asynchronous: every call takes a result callback and the
 * reply/error are owned by the binding and valid only for the duration of that
 * callback. So each callback *copies out* what it needs into a waiter struct,
 * and the test polls a `done` flag (the same volatile-flag pattern the event
 * listener uses) to turn each async call back into a sequential check. The
 * caller never frees reply data or error strings — that is the whole point. */
#include "my_timer.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static void wait_done(volatile int* done) {
    for (int i = 0; i < 500 && !*done; i++) {
        struct timespec t = {0, 10 * 1000 * 1000}; /* 10ms */
        nanosleep(&t, NULL);
    }
    assert(*done);
}

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

typedef struct {
    volatile int done;
    int err_code;
    MyTimerCtx* ctx;
    char err[256];
} CreateWaiter;

static void on_created(int ec, MyTimerCtx* ctx, const char* em, void* ud) {
    CreateWaiter* w = (CreateWaiter*)ud;
    w->err_code = ec;
    w->ctx = ctx;
    if (em) {
        snprintf(w->err, sizeof(w->err), "%s", em);
    }
    w->done = 1;
}

static MyTimerCtx* make_ctx(void) {
    CreateWaiter w;
    memset(&w, 0, sizeof(w));
    TimerConfig config = {nimffi_str("c-e2e")};
    my_timer_ctx_create(&config, on_created, &w);
    wait_done(&w.done);
    if (w.err_code != 0) {
        fprintf(stderr, "create failed: %s\n", w.err[0] ? w.err : "?");
    }
    assert(w.err_code == 0);
    assert(w.ctx != NULL);
    return w.ctx;
}

typedef struct {
    volatile int done;
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
    w->done = 1;
}

static void test_version(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    my_timer_ctx_version(ctx, on_version, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, TIMER_VERSION) == 0);
}

static void on_echo(int ec, const EchoResponse* reply, const char* em, void* ud) {
    ReplyWaiter* w = (ReplyWaiter*)ud;
    w->err_code = ec;
    if (reply) {
        if (reply->echoed.data) snprintf(w->text_a, sizeof(w->text_a), "%s", reply->echoed.data);
        if (reply->timerName.data)
            snprintf(w->text_b, sizeof(w->text_b), "%s", reply->timerName.data);
    }
    if (em) snprintf(w->err, sizeof(w->err), "%s", em);
    w->done = 1;
}

static void test_echo(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {nimffi_str("hello"), 10};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, "hello") == 0);
    assert(strcmp(w.text_b, "c-e2e") == 0);
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
    w->done = 1;
}

static void test_complex(MyTimerCtx* ctx) {
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

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    my_timer_ctx_complex(ctx, &req, on_complex, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(w.num_a == 2);
    assert(w.flag == true);
    assert(strstr(w.text_a, "note=note") != NULL);
}

static void on_schedule(int ec, const ScheduleResult* reply, const char* em, void* ud) {
    ReplyWaiter* w = (ReplyWaiter*)ud;
    w->err_code = ec;
    if (reply) {
        w->num_a = (long long)reply->willRunCount;
        w->num_b = (long long)reply->effectiveBackoffMs;
        w->flag = (int)reply->priority;
        if (reply->jobId.data) snprintf(w->text_a, sizeof(w->text_a), "%s", reply->jobId.data);
    }
    if (em) snprintf(w->err, sizeof(w->err), "%s", em);
    w->done = 1;
}

static void test_schedule_ok(MyTimerCtx* ctx) {
    NimFfiStr payload[1] = {nimffi_str("p")};
    JobSpec job;
    job.name = nimffi_str("rollup");
    job.payload.data = payload;
    job.payload.len = 1;
    job.priority = JOB_PRIORITY_JP_HIGH;

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

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    my_timer_ctx_schedule(ctx, &job, &retry, &sched, on_schedule, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, "c-e2e:rollup") == 0);
    assert(w.num_a == 1);
    /* jpHigh halves the requested 100ms backoff. */
    assert(w.num_b == 50);
    assert(w.flag == JOB_PRIORITY_JP_HIGH);
}

static void test_schedule_error(MyTimerCtx* ctx) {
    NimFfiStr payload[1] = {nimffi_str("p")};
    JobSpec job;
    job.name = nimffi_str(""); /* empty name → handler returns err */
    job.payload.data = payload;
    job.payload.len = 1;
    job.priority = JOB_PRIORITY_JP_LOW;

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

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    my_timer_ctx_schedule(ctx, &job, &retry, &sched, on_schedule, &w);
    wait_done(&w.done);
    assert(w.err_code != 0);
    assert(w.err[0] != '\0');
    assert(strstr(w.err, "job name") != NULL);
}

static void test_delay_limit(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {nimffi_str("too-slow"), MAX_DELAY_MS + 1};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);
    wait_done(&w.done);
    assert(w.err_code != 0);
    assert(strstr(w.err, "delayMs") != NULL);
}

static void test_event(MyTimerCtx* ctx) {
    int hits = 0;
    uint64_t handle =
        my_timer_ctx_add_on_echo_fired_listener(ctx, on_echo_fired, &hits);
    assert(handle != 0);

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {nimffi_str("evt"), 1};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);

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
    test_delay_limit(ctx);
    test_event(ctx);
    assert(my_timer_ctx_destroy(ctx) == NIMFFI_RET_OK);
    printf("all C e2e checks passed\n");
    return 0;
}
