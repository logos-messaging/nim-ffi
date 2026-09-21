/* End-to-end test for the generated C timer bindings. Exercises the same
 * surface as the C++ suite: constructor, methods, nested seq/Option payloads,
 * multi-parameter requests, the error channel, and the events the host takes
 * out with the dispatch thread or after a wait on the wake handle.
 * It aborts (non-zero exit) on the first failure so ctest reports it.
 *
 * The binding is asynchronous: the reply and the error string are owned by the
 * binding and valid only inside the result callback, so each callback copies
 * out what it needs into a waiter (see waiter.h). The caller never frees reply
 * data or error strings, which is the whole point. */
#include "my_timer.h"
#include "waiter.h"

#if !defined(_WIN32)
#  include <poll.h>
#  include <unistd.h>
#endif

/* Handlers run on the thread that dispatches, which is main here: no atomics. */
typedef struct {
    int echo_hits;
    int scheduled_hits;
    long long echo_count;
    char message[256];
    char job_id[256];
} EventSink;

static void on_echo_fired(const EchoEvent* ev, void* user_data) {
    EventSink* sink = (EventSink*)user_data;
    sink->echo_hits++;
    sink->echo_count = (long long)ev->echoCount;
    snprintf(sink->message, sizeof(sink->message), "%s", ev->message ? ev->message : "");
}

static void on_job_scheduled(const OnJobScheduledPayload* ev, void* user_data) {
    EventSink* sink = (EventSink*)user_data;
    sink->scheduled_hits++;
    snprintf(sink->job_id, sizeof(sink->job_id), "%s", ev->jobId ? ev->jobId : "");
}

static MyTimerHandlers sink_handlers(EventSink* sink) {
    MyTimerHandlers handlers;
    memset(&handlers, 0, sizeof(handlers));
    handlers.on_echo_fired = on_echo_fired;
    handlers.on_job_scheduled = on_job_scheduled;
    handlers.user_data = sink;
    return handlers;
}

/* Takes out what is queued without waiting. Returns the number of messages. */
static int drain(MyTimerCtx* ctx, const MyTimerHandlers* handlers) {
    int taken = 0;
    for (;;) {
        int rc = my_timer_ctx_dispatch_next(ctx, 0, handlers);
        if (rc == NIMFFI_RET_TIMEOUT) return taken;
        assert(rc == NIMFFI_RET_OK);
        taken++;
    }
}

/* Per library: the ctor callback's context parameter is a distinct type. */
static void on_created(int err_code, MyTimerCtx* ctx, const char* err_msg, void* user_data) {
    CreateWaiter* w = (CreateWaiter*)user_data;
    w->err_code = err_code;
    w->ctx = ctx;
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

static MyTimerCtx* make_ctx(void) {
    CreateWaiter w;
    memset(&w, 0, sizeof(w));
    TimerConfig config = {"c-e2e"};
    my_timer_ctx_create(&config, on_created, &w);
    wait_done(&w.done);
    if (w.err_code != 0) {
        fprintf(stderr, "create failed: %s\n", w.err[0] ? w.err : "?");
    }
    assert(w.err_code == 0);
    assert(w.ctx != NULL);
    return (MyTimerCtx*)w.ctx;
}

static void test_version(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    my_timer_ctx_version(ctx, on_str, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, TIMER_VERSION) == 0);
}

static void on_echo(int err_code, const EchoResponse* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->err_code = err_code;
    if (reply) {
        if (reply->echoed) snprintf(w->text_a, sizeof(w->text_a), "%s", reply->echoed);
        if (reply->timerName)
            snprintf(w->text_b, sizeof(w->text_b), "%s", reply->timerName);
    }
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

static void test_echo(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {"hello", 10};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, "hello") == 0);
    assert(strcmp(w.text_b, "c-e2e") == 0);
}

static void on_complex(int err_code, const ComplexResponse* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->err_code = err_code;
    if (reply) {
        w->num_a = (long long)reply->itemCount;
        w->flag = (int)reply->hasNote;
        if (reply->summary)
            snprintf(w->text_a, sizeof(w->text_a), "%s", reply->summary);
    }
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

static void test_complex(MyTimerCtx* ctx) {
    EchoRequest items[2] = {{"one", 1}, {"two", 2}};
    const char* tags[2] = {"a", "b"};
    ComplexRequest req;
    req.messages.data = items;
    req.messages.len = 2;
    req.tags.data = tags;
    req.tags.len = 2;
    req.note.has_value = true;
    req.note.value = "note";
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

static void on_schedule(int err_code, const ScheduleResult* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->err_code = err_code;
    if (reply) {
        w->num_a = (long long)reply->willRunCount;
        w->num_b = (long long)reply->effectiveBackoffMs;
        w->flag = (int)reply->priority;
        if (reply->jobId) snprintf(w->text_a, sizeof(w->text_a), "%s", reply->jobId);
    }
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

static void test_schedule_ok(MyTimerCtx* ctx) {
    const char* payload[1] = {"p"};
    JobSpec job;
    job.name = "rollup";
    job.payload.data = payload;
    job.payload.len = 1;
    job.priority = JOB_PRIORITY_JP_HIGH;

    const char* retry_on[1] = {"timeout"};
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
    const char* payload[1] = {"p"};
    JobSpec job;
    job.name = ""; /* empty name → handler returns err */
    job.payload.data = payload;
    job.payload.len = 1;
    job.priority = JOB_PRIORITY_JP_LOW;

    const char* retry_on[1] = {"timeout"};
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
    EchoRequest req = {"too-slow", MAX_DELAY_MS + 1};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);
    wait_done(&w.done);
    assert(w.err_code != 0);
    assert(strstr(w.err, "delayMs") != NULL);
}

/* The requests above fired events nobody took out: they wait, in order. */
static void test_queued_events(MyTimerCtx* ctx) {
    EventSink sink;
    memset(&sink, 0, sizeof(sink));
    MyTimerHandlers handlers = sink_handlers(&sink);
    /* An event is queued before its request is answered, so both are here. */
    assert(drain(ctx, &handlers) == 2);
    assert(sink.echo_hits == 1);
    assert(strcmp(sink.message, "hello") == 0);
    assert(sink.scheduled_hits == 1);
    assert(strcmp(sink.job_id, "c-e2e:rollup") == 0);
    /* Empty now, and an empty poll does not block. */
    assert(my_timer_ctx_dispatch_next(ctx, 0, &handlers) == NIMFFI_RET_TIMEOUT);
}

static void test_event(MyTimerCtx* ctx) {
    EventSink sink;
    memset(&sink, 0, sizeof(sink));
    MyTimerHandlers handlers = sink_handlers(&sink);

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {"evt", 1};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);

    long long deadline = now_ms() + 5000;
    while (sink.echo_hits == 0 && now_ms() < deadline) {
        int rc = my_timer_ctx_dispatch_next(ctx, 50, &handlers);
        assert(rc == NIMFFI_RET_OK || rc == NIMFFI_RET_TIMEOUT);
    }
    assert(sink.echo_hits == 1);
    assert(strcmp(sink.message, "evt") == 0);
    assert(sink.echo_count == 1);

    wait_done(&w.done);
    assert(w.err_code == 0);
}

/* A NULL entry, or no handlers at all, ignores the message without leaking it. */
static void test_ignored_event(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {"ignored", 1};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);

    int rc = NIMFFI_RET_TIMEOUT;
    long long deadline = now_ms() + 5000;
    while (rc == NIMFFI_RET_TIMEOUT && now_ms() < deadline) {
        rc = my_timer_ctx_dispatch_next(ctx, 50, NULL);
    }
    assert(rc == NIMFFI_RET_OK);
}

/* The raw decoder: the caller owns what it decodes. */
static void test_decode(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {"raw", 1};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);

    const NimFfiMsg* msg = NULL;
    assert(my_timer_poll(ctx->ptr, 5000, &msg) == NIMFFI_RET_OK);
    assert(msg != NULL);
    assert(msg->kind == NIMFFI_MSG_EVENT);
    assert(msg->name_id == MY_TIMER_EVT_ON_ECHO_FIRED);

    OnJobScheduledPayload wrong;
    assert(my_timer_decode_on_job_scheduled(msg, &wrong) != 0);

    EchoEvent ev;
    assert(my_timer_decode_on_echo_fired(msg, &ev) == 0);
    assert(strcmp(ev.message, "raw") == 0);
    my_timer_free_EchoEvent(&ev);

    /* A truncated payload is a decode error, not a crash. */
    NimFfiMsg cut = *msg;
    cut.len = msg->len / 2;
    assert(my_timer_decode_on_echo_fired(&cut, &ev) != 0);
    assert(my_timer_ctx_dispatch(ctx, &cut, NULL) < 0);

    NimFfiMsg unknown = *msg;
    unknown.name_id = 1;
    assert(my_timer_ctx_dispatch(ctx, &unknown, NULL) == 0);
    unknown.kind = 999;
    assert(my_timer_ctx_dispatch(ctx, &unknown, NULL) < 0);
}

/* Waits on the wake handle until it is ready or `timeout_ms` passed. */
static bool wait_ready(intptr_t handle, int timeout_ms) {
#if defined(_WIN32)
    return WaitForSingleObject((HANDLE)handle, (DWORD)timeout_ms) == WAIT_OBJECT_0;
#else
    struct pollfd pfd;
    memset(&pfd, 0, sizeof(pfd));
    pfd.fd = (int)handle;
    pfd.events = POLLIN;
    return poll(&pfd, 1, timeout_ms) == 1 && (pfd.revents & POLLIN) != 0;
#endif
}

static void close_handle(intptr_t handle) {
#if defined(_WIN32)
    assert(CloseHandle((HANDLE)handle));
#else
    assert(close((int)handle) == 0);
#endif
}

/* A host with a loop of its own waits on the handle, then drains. */
static void test_poll_fd(MyTimerCtx* ctx) {
    EventSink sink;
    memset(&sink, 0, sizeof(sink));
    MyTimerHandlers handlers = sink_handlers(&sink);

    intptr_t handle = my_timer_ctx_poll_fd(ctx);
    assert(handle != -1);
    assert(drain(ctx, &handlers) == 0);
    assert(!wait_ready(handle, 0));

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {"fd", 1};
    my_timer_ctx_echo(ctx, &req, on_echo, &w);

    assert(wait_ready(handle, 5000));
    assert(drain(ctx, &handlers) == 1);
    assert(strcmp(sink.message, "fd") == 0);
    /* Drained: the handle is quiet again. */
    assert(!wait_ready(handle, 0));

    wait_done(&w.done);
    assert(w.err_code == 0);
    close_handle(handle);
}

/* The handle outlives the context, the token does not. */
static void test_destroy(MyTimerCtx* ctx) {
    intptr_t handle = my_timer_ctx_poll_fd(ctx);
    assert(handle != -1);
    void* token = ctx->ptr;

    assert(my_timer_ctx_destroy(ctx) == NIMFFI_RET_OK);

    const NimFfiMsg* msg = NULL;
    assert(my_timer_poll(token, 0, &msg) == NIMFFI_RET_INVALID_CTX);
    assert(msg == NULL);
    assert(my_timer_poll_fd(token) == -1);
    assert(my_timer_ctx_dispatch_next(NULL, 0, NULL) == NIMFFI_RET_INVALID_CTX);
    assert(my_timer_ctx_poll_fd(NULL) == -1);
    close_handle(handle);
}

int main(void) {
    MyTimerCtx* ctx = make_ctx();
    test_version(ctx);
    test_echo(ctx);
    test_complex(ctx);
    test_schedule_ok(ctx);
    test_schedule_error(ctx);
    test_delay_limit(ctx);
    test_queued_events(ctx);
    test_event(ctx);
    test_ignored_event(ctx);
    test_decode(ctx);
    test_poll_fd(ctx);
    test_destroy(ctx);
    printf("all C e2e checks passed\n");
    return 0;
}
