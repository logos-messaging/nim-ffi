/* End-to-end test for the generated C timer bindings. Exercises the same
 * surface as the C++ suite: constructor, methods, nested seq/Option payloads,
 * multi-parameter requests, the error channel, and the events.
 * It aborts (non-zero exit) on the first failure so ctest reports it.
 *
 * The library calls nothing back and the binding starts no thread: a reply or
 * an event reaches this program only while it pumps, either itself or inside a
 * `_sync` helper. What an on_reply is handed belongs to the binding and is valid
 * only inside it, so each callback copies out what it needs into a waiter (see
 * waiter.h); what a `_sync` helper hands out belongs to the caller. */
#include "my_timer.h"
#include "waiter.h"

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  define NOMINMAX
#  include <windows.h>
#else
#  include <poll.h>
#  include <unistd.h>
#endif

typedef struct {
    int echo_hits;
    int scheduled_hits;
    int stale_hits;
    int closed_hits;
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

static void on_stale_warn(uint64_t req_id, uint64_t elapsed_ms, void* user_data) {
    EventSink* sink = (EventSink*)user_data;
    assert(req_id == 7 && elapsed_ms == 5000);
    sink->stale_hits++;
}

static void on_closed(int ret, const char* reason, void* user_data) {
    EventSink* sink = (EventSink*)user_data;
    assert(ret == NIMFFI_RET_OK && reason == NULL);
    sink->closed_hits++;
}

static MyTimerHandlers sink_handlers(EventSink* sink) {
    MyTimerHandlers handlers;
    memset(&handlers, 0, sizeof(handlers));
    handlers.on_echo_fired = on_echo_fired;
    handlers.on_job_scheduled = on_job_scheduled;
    handlers.stale_warn = on_stale_warn;
    handlers.closed = on_closed;
    handlers.user_data = sink;
    return handlers;
}

/* Takes out what is queued without waiting. Returns the number of messages. */
static int drain(MyTimerCtx* ctx, const MyTimerHandlers* handlers) {
    int taken = 0;
    for (;;) {
        int rc = my_timer_ctx_pump_once(ctx, 0, handlers);
        if (rc == NIMFFI_RET_TIMEOUT) return taken;
        assert(rc == NIMFFI_RET_OK);
        taken++;
    }
}

static MyTimerCtx* make_ctx(void) {
    TimerConfig config = {"c-e2e"};
    MyTimerCtx* ctx = NULL;
    char* err = NULL;
    int rc = my_timer_ctx_create_sync(&config, &ctx, &err, WAIT_LIMIT_MS);
    if (rc != NIMFFI_RET_OK) {
        fprintf(stderr, "create failed (%d): %s\n", rc, err ? err : "?");
    }
    assert(rc == NIMFFI_RET_OK);
    assert(ctx != NULL && ctx->ptr != NULL && err == NULL);
    assert(ctx->pending.len == 0);
    return ctx;
}

/* The context is handed out at once, so that the host can pump it for the reply. */
static void test_create_async(void) {
    CreateWaiter w;
    memset(&w, 0, sizeof(w));
    TimerConfig config = {"c-e2e-async"};
    MyTimerCtx* ctx = NULL;
    assert(my_timer_ctx_create(&config, &ctx, on_created, &w) == NIMFFI_RET_OK);
    assert(ctx != NULL && ctx->ptr != NULL);
    assert(w.done == 0);
    WAIT_DONE(w.done, my_timer_ctx_pump_once(ctx, 50, NULL));
    assert(w.done == 1 && w.ret == NIMFFI_RET_OK && w.err[0] == '\0');

    const char* version = NULL;
    assert(my_timer_ctx_version_sync(ctx, &version, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(strcmp(version, TIMER_VERSION) == 0);
    free((void*)version);
    assert(my_timer_ctx_destroy(ctx) == NIMFFI_RET_OK);
}

static void test_version(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    assert(my_timer_ctx_version(ctx, on_str, &w, NULL) == NIMFFI_RET_OK);
    /* Nothing runs before the host pumps. */
    assert(w.done == 0 && ctx->pending.len == 1);
    WAIT_DONE(w.done, my_timer_ctx_pump_once(ctx, 50, NULL));
    assert(w.done == 1 && w.ret == NIMFFI_RET_OK);
    assert(strcmp(w.text_a, TIMER_VERSION) == 0);
    assert(ctx->pending.len == 0);
}

static void on_echo(int ret, const EchoResponse* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->ret = ret;
    if (reply) {
        if (reply->echoed) snprintf(w->text_a, sizeof(w->text_a), "%s", reply->echoed);
        if (reply->timerName)
            snprintf(w->text_b, sizeof(w->text_b), "%s", reply->timerName);
    }
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

/* An event is queued before its request is answered. */
static void test_echo(MyTimerCtx* ctx) {
    EventSink sink;
    memset(&sink, 0, sizeof(sink));
    MyTimerHandlers handlers = sink_handlers(&sink);

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {"hello", 10};
    assert(my_timer_ctx_echo(ctx, &req, on_echo, &w, NULL) == NIMFFI_RET_OK);
    while (!w.done) {
        assert(sink.echo_hits <= 1);
        int rc = my_timer_ctx_pump_once(ctx, WAIT_LIMIT_MS, &handlers);
        assert(rc == NIMFFI_RET_OK);
    }
    assert(w.done == 1 && w.ret == NIMFFI_RET_OK);
    assert(strcmp(w.text_a, "hello") == 0);
    assert(strcmp(w.text_b, "c-e2e") == 0);
    assert(sink.echo_hits == 1);
    assert(strcmp(sink.message, "hello") == 0);
    assert(sink.echo_count == 1);
    assert(my_timer_ctx_pump_once(ctx, 0, &handlers) == NIMFFI_RET_TIMEOUT);
}

/* The sequential shape: the helper pumps, and everything else that arrives
 * meanwhile goes to the handlers. The caller owns what it is handed. */
static void test_echo_sync(MyTimerCtx* ctx) {
    EventSink sink;
    memset(&sink, 0, sizeof(sink));
    MyTimerHandlers handlers = sink_handlers(&sink);

    EchoRequest req = {"sync", 10};
    EchoResponse out;
    char* err = NULL;
    assert(my_timer_ctx_echo_sync(ctx, &req, &out, &err, WAIT_LIMIT_MS, &handlers) == NIMFFI_RET_OK);
    assert(err == NULL);
    assert(strcmp(out.echoed, "sync") == 0);
    assert(strcmp(out.timerName, "c-e2e") == 0);
    my_timer_free_EchoResponse(&out);
    assert(sink.echo_hits == 1);
    assert(strcmp(sink.message, "sync") == 0);
    assert(ctx->pending.len == 0);
}

static void on_complex(int ret, const ComplexResponse* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->ret = ret;
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
    assert(my_timer_ctx_complex(ctx, &req, on_complex, &w, NULL) == NIMFFI_RET_OK);
    WAIT_DONE(w.done, my_timer_ctx_pump_once(ctx, 50, NULL));
    assert(w.ret == NIMFFI_RET_OK);
    assert(w.num_a == 2);
    assert(w.flag == true);
    assert(strstr(w.text_a, "note=note") != NULL);

    ComplexResponse out;
    assert(my_timer_ctx_complex_sync(ctx, &req, &out, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(out.itemCount == 2 && out.hasNote);
    my_timer_free_ComplexResponse(&out);
}

static void on_schedule(int ret, const ScheduleResult* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->ret = ret;
    if (reply) {
        w->num_a = (long long)reply->willRunCount;
        w->num_b = (long long)reply->effectiveBackoffMs;
        w->flag = (int)reply->priority;
        if (reply->jobId) snprintf(w->text_a, sizeof(w->text_a), "%s", reply->jobId);
    }
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

typedef struct {
    const char* payload[1];
    const char* retry_on[1];
    JobSpec job;
    RetryPolicy retry;
    ScheduleConfig sched;
} ScheduleArgs;

static void schedule_args(ScheduleArgs* a, const char* name, JobPriority priority) {
    a->payload[0] = "p";
    a->retry_on[0] = "timeout";
    a->job.name = name;
    a->job.payload.data = a->payload;
    a->job.payload.len = 1;
    a->job.priority = priority;
    a->retry.maxAttempts = 3;
    a->retry.backoffMs = 100;
    a->retry.retryOn.data = a->retry_on;
    a->retry.retryOn.len = 1;
    a->sched.startAtMs = 1000;
    a->sched.intervalMs = 0;
    a->sched.jitter.has_value = false;
    a->sched.jitter.value = 0;
}

static void test_schedule_ok(MyTimerCtx* ctx) {
    EventSink sink;
    memset(&sink, 0, sizeof(sink));
    MyTimerHandlers handlers = sink_handlers(&sink);
    ScheduleArgs a;
    schedule_args(&a, "rollup", JOB_PRIORITY_JP_HIGH);

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    assert(my_timer_ctx_schedule(ctx, &a.job, &a.retry, &a.sched, on_schedule, &w, NULL) == NIMFFI_RET_OK);
    WAIT_DONE(w.done, my_timer_ctx_pump_once(ctx, 50, &handlers));
    assert(w.ret == NIMFFI_RET_OK);
    assert(strcmp(w.text_a, "c-e2e:rollup") == 0);
    assert(w.num_a == 1);
    /* jpHigh halves the requested 100ms backoff. */
    assert(w.num_b == 50);
    assert(w.flag == JOB_PRIORITY_JP_HIGH);
    assert(sink.scheduled_hits == 1);
    assert(strcmp(sink.job_id, "c-e2e:rollup") == 0);
}

static void test_schedule_error(MyTimerCtx* ctx) {
    ScheduleArgs a;
    schedule_args(&a, "", JOB_PRIORITY_JP_LOW); /* empty name → handler returns err */

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    assert(my_timer_ctx_schedule(ctx, &a.job, &a.retry, &a.sched, on_schedule, &w, NULL) == NIMFFI_RET_OK);
    WAIT_DONE(w.done, my_timer_ctx_pump_once(ctx, 50, NULL));
    assert(w.done == 1 && w.ret == NIMFFI_RET_ERR);
    assert(strstr(w.err, "job name") != NULL);
}

/* A request the library answers with an error: the code, the text, a zeroed out. */
static void test_sync_error(MyTimerCtx* ctx) {
    EchoRequest req = {"too-slow", MAX_DELAY_MS + 1};
    EchoResponse out;
    memset(&out, 0xff, sizeof(out));
    char* err = NULL;
    assert(my_timer_ctx_echo_sync(ctx, &req, &out, &err, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_ERR);
    assert(err != NULL && strstr(err, "delayMs") != NULL);
    free(err);
    assert(out.echoed == NULL && out.timerName == NULL);

    /* `err` may be NULL. */
    assert(my_timer_ctx_echo_sync(ctx, &req, &out, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_ERR);

    ScheduleArgs a;
    schedule_args(&a, "", JOB_PRIORITY_JP_LOW);
    ScheduleResult res;
    assert(my_timer_ctx_schedule_sync(ctx, &a.job, &a.retry, &a.sched, &res, &err, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_ERR);
    assert(err != NULL && strstr(err, "job name") != NULL);
    free(err);
}

/* A reply that comes after its `_sync` call gave up is dropped: nothing is left
 * that points into the dead stack frame, and the next call gets its own reply. */
static void test_sync_timeout(MyTimerCtx* ctx) {
    EchoRequest slow = {"late", 300};
    EchoResponse out;
    char* err = NULL;
    assert(my_timer_ctx_echo_sync(ctx, &slow, &out, &err, 20, NULL) == NIMFFI_RET_TIMEOUT);
    assert(err == NULL && out.echoed == NULL);
    assert(ctx->pending.len == 0);

    const char* version = NULL;
    assert(my_timer_ctx_version_sync(ctx, &version, &err, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(strcmp(version, TIMER_VERSION) == 0);
    free((void*)version);

    /* The late event and the late reply still come out; nobody waits for the reply. */
    int64_t deadline = nimffi_now_ms() + WAIT_LIMIT_MS;
    int taken = 0;
    while (taken < 2 && nimffi_now_ms() < deadline) {
        int rc = my_timer_ctx_pump_once(ctx, 50, NULL);
        assert(rc == NIMFFI_RET_OK || rc == NIMFFI_RET_TIMEOUT);
        if (rc == NIMFFI_RET_OK) taken++;
    }
    assert(taken == 2);

    /* A timeout of 0 still looks once, and a request that answers at once may make it. */
    EchoRequest fast = {"zero", 0};
    int rc = my_timer_ctx_echo_sync(ctx, &fast, &out, NULL, 0, NULL);
    assert(rc == NIMFFI_RET_OK || rc == NIMFFI_RET_TIMEOUT);
    if (rc == NIMFFI_RET_OK) my_timer_free_EchoResponse(&out);
    assert(ctx->pending.len == 0);
    while (my_timer_ctx_pump_once(ctx, 100, NULL) == NIMFFI_RET_OK) {
    }
}

typedef struct {
    ReplyWaiter w;
    int* order;
    int position;
} OrderedWaiter;

static void on_echo_ordered(int ret, const EchoResponse* reply, const char* err_msg, void* user_data) {
    OrderedWaiter* ow = (OrderedWaiter*)user_data;
    ow->position = (*ow->order)++;
    on_echo(ret, reply, err_msg, &ow->w);
}

/* Several requests in flight: each reply finds its own callback, in the order
 * the library answers, not the order of the submits. */
static void test_in_flight(MyTimerCtx* ctx) {
    const char* names[3] = {"slow", "mid", "fast"};
    const int64_t delays[3] = {160, 80, 5};
    OrderedWaiter ow[3];
    int order = 0;
    memset(ow, 0, sizeof(ow));
    for (int i = 0; i < 3; i++) {
        ow[i].order = &order;
        EchoRequest req = {names[i], delays[i]};
        assert(my_timer_ctx_echo(ctx, &req, on_echo_ordered, &ow[i], NULL) == NIMFFI_RET_OK);
    }
    assert(ctx->pending.len == 3);
    WAIT_DONE(order == 3, my_timer_ctx_pump_once(ctx, 50, NULL));
    for (int i = 0; i < 3; i++) {
        assert(ow[i].w.done == 1 && ow[i].w.ret == NIMFFI_RET_OK);
        assert(strcmp(ow[i].w.text_a, names[i]) == 0);
        assert(ow[i].position == 2 - i);
    }
    assert(ctx->pending.len == 0);
    /* The three events came out with the replies. */
    assert(drain(ctx, NULL) == 0);
}

/* A `_sync` call made while other requests are in flight settles them too. */
static void test_sync_among_async(MyTimerCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest quick = {"quick", 1};
    assert(my_timer_ctx_echo(ctx, &quick, on_echo, &w, NULL) == NIMFFI_RET_OK);

    EchoRequest slow = {"slower", 60};
    EchoResponse out;
    assert(my_timer_ctx_echo_sync(ctx, &slow, &out, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(strcmp(out.echoed, "slower") == 0);
    my_timer_free_EchoResponse(&out);
    assert(w.done == 1 && strcmp(w.text_a, "quick") == 0);
}

/* A handler may itself make a `_sync` request: the pump it runs in has already
 * let go of the message. */
typedef struct {
    MyTimerCtx* ctx;
    int hits;
    char version[64];
} NestedSink;

static void on_echo_fired_nested(const EchoEvent* ev, void* user_data) {
    NestedSink* sink = (NestedSink*)user_data;
    const char* version = NULL;
    assert(my_timer_ctx_version_sync(sink->ctx, &version, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    snprintf(sink->version, sizeof(sink->version), "%s", version);
    free((void*)version);
    /* The event outlives the nested pump: it was decoded before the handler ran. */
    assert(strcmp(ev->message, "nested") == 0);
    sink->hits++;
}

static void test_sync_inside_handler(MyTimerCtx* ctx) {
    NestedSink sink;
    memset(&sink, 0, sizeof(sink));
    sink.ctx = ctx;
    MyTimerHandlers handlers;
    memset(&handlers, 0, sizeof(handlers));
    handlers.on_echo_fired = on_echo_fired_nested;
    handlers.user_data = &sink;

    EchoRequest req = {"nested", 5};
    EchoResponse out;
    assert(my_timer_ctx_echo_sync(ctx, &req, &out, NULL, WAIT_LIMIT_MS, &handlers) == NIMFFI_RET_OK);
    assert(strcmp(out.echoed, "nested") == 0);
    my_timer_free_EchoResponse(&out);
    assert(sink.hits == 1);
    assert(strcmp(sink.version, TIMER_VERSION) == 0);
    assert(ctx->pending.len == 0);
}

/* A refused submit returns the library's code, leaves its text in last_error,
 * records nothing and calls nothing. */
static void test_refused_submit(void) {
    TimerConfig config = {"c-e2e-stale"};
    MyTimerCtx* gone = NULL;
    assert(my_timer_ctx_create_sync(&config, &gone, NULL, WAIT_LIMIT_MS) == NIMFFI_RET_OK);
    MyTimerCtx stale;
    memset(&stale, 0, sizeof(stale));
    stale.ptr = gone->ptr;
    assert(my_timer_ctx_destroy(gone) == NIMFFI_RET_OK);

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    assert(my_timer_ctx_version(&stale, on_str, &w, NULL) == NIMFFI_RET_INVALID_CTX);
    assert(strstr(my_timer_last_error(), "not a valid FFI context") != NULL);
    assert(w.done == 0 && stale.pending.len == 0);

    EchoRequest req = {"refused", 1};
    EchoResponse out;
    char* err = NULL;
    assert(my_timer_ctx_echo_sync(&stale, &req, &out, &err, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_INVALID_CTX);
    assert(err != NULL && strstr(err, "not a valid FFI context") != NULL);
    free(err);
    assert(out.echoed == NULL && stale.pending.len == 0);
    assert(my_timer_ctx_pump_once(&stale, 0, NULL) == NIMFFI_RET_INVALID_CTX);
    assert(w.done == 0);
    /* `stale` was built by hand, so nothing else frees the room a submit made. */
    free(stale.pending.items);

    assert(my_timer_ctx_version(NULL, on_str, &w, NULL) == NIMFFI_RET_INVALID_CTX);
    const char* version = NULL;
    assert(my_timer_ctx_version_sync(NULL, &version, &err, 0, NULL) == NIMFFI_RET_INVALID_CTX);
    assert(err != NULL);
    free(err);
    assert(w.done == 0);
}

/* {.ffiStatic.} procs take no context: their replies arrive on the static one. */
static void test_statics(void) {
    const char* version = NULL;
    char* err = NULL;
    assert(my_timer_static_lib_version_sync(&version, &err, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(err == NULL && strcmp(version, TIMER_VERSION) == 0);
    free((void*)version);

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    assert(my_timer_static_lib_version(on_str, &w, NULL) == NIMFFI_RET_OK);
    assert(w.done == 0);
    WAIT_DONE(w.done, my_timer_static_pump_once(50, NULL));
    assert(w.done == 1 && w.ret == NIMFFI_RET_OK);
    assert(strcmp(w.text_a, TIMER_VERSION) == 0);
    assert(my_timer_static_pump_once(0, NULL) == NIMFFI_RET_TIMEOUT);
}

/* A NULL entry, or no handlers at all, ignores the message without leaking it. */
static void test_ignored_event(MyTimerCtx* ctx) {
    EchoRequest req = {"ignored", 1};
    EchoResponse out;
    assert(my_timer_ctx_echo_sync(ctx, &req, &out, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    my_timer_free_EchoResponse(&out);
    assert(drain(ctx, NULL) == 0);
}

/* The raw path: a host that polls itself submits through the export and decodes
 * with the typed decoders. It owns what it decodes. */
static void test_raw(MyTimerCtx* ctx) {
    MyTimerEchoReq raw_req;
    memset(&raw_req, 0, sizeof(raw_req));
    raw_req.req.message = "raw";
    raw_req.req.delayMs = 1;
    uint8_t* buf = NULL;
    size_t len = 0;
    assert(nimffi_encode_to_buf(my_timer_encv_MyTimerEchoReq, &raw_req, &buf, &len, NULL) == 0);
    uint64_t req_id = 0;
    assert(my_timer_echo(ctx->ptr, buf, len, NULL) == NIMFFI_RET_ERR);
    assert(my_timer_last_error()[0] != '\0');
    assert(my_timer_echo(ctx->ptr, buf, len, &req_id) == NIMFFI_RET_OK);
    assert(req_id != 0);

    const NimFfiMsg* msg = NULL;
    assert(my_timer_poll(ctx->ptr, WAIT_LIMIT_MS, &msg) == NIMFFI_RET_OK);
    assert(msg != NULL);
    assert(msg->kind == NIMFFI_MSG_EVENT);
    assert(msg->name_id == MY_TIMER_EVT_ON_ECHO_FIRED);

    OnJobScheduledPayload wrong;
    assert(my_timer_decode_on_job_scheduled(msg, &wrong) != 0);
    EchoResponse out;
    char* err = NULL;
    assert(my_timer_decode_echo_reply(msg, &out, &err) == -1);
    assert(err != NULL);
    free(err);

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

    assert(my_timer_poll(ctx->ptr, WAIT_LIMIT_MS, &msg) == NIMFFI_RET_OK);
    assert(msg->kind == NIMFFI_MSG_REPLY);
    assert(msg->id == req_id && msg->ret_code == NIMFFI_RET_OK);
    assert(my_timer_decode_on_echo_fired(msg, &ev) != 0);
    assert(my_timer_decode_echo_reply(msg, &out, &err) == NIMFFI_RET_OK);
    assert(err == NULL && strcmp(out.echoed, "raw") == 0);
    my_timer_free_EchoResponse(&out);

    cut = *msg;
    cut.len = msg->len / 2;
    assert(my_timer_decode_echo_reply(&cut, &out, &err) == -1);
    assert(err != NULL && out.echoed == NULL);
    free(err);
    /* The binding did not submit it, so its table does not know the id. */
    assert(my_timer_ctx_dispatch(ctx, msg, NULL) == 0);

    /* An error reply: the payload is text, handed out as a C string. */
    raw_req.req.delayMs = MAX_DELAY_MS + 1;
    free(buf);
    assert(nimffi_encode_to_buf(my_timer_encv_MyTimerEchoReq, &raw_req, &buf, &len, NULL) == 0);
    assert(my_timer_echo(ctx->ptr, buf, len, &req_id) == NIMFFI_RET_OK);
    free(buf);
    assert(my_timer_poll(ctx->ptr, WAIT_LIMIT_MS, &msg) == NIMFFI_RET_OK);
    assert(msg->kind == NIMFFI_MSG_REPLY && msg->id == req_id);
    assert(my_timer_decode_echo_reply(msg, &out, &err) == NIMFFI_RET_ERR);
    assert(err != NULL && strstr(err, "delayMs") != NULL);
    free(err);
}

/* Messages only a long-running or dying context produces, dispatched by hand. */
static void test_dispatch_liveness(MyTimerCtx* ctx) {
    EventSink sink;
    memset(&sink, 0, sizeof(sink));
    MyTimerHandlers handlers = sink_handlers(&sink);

    NimFfiMsg msg;
    memset(&msg, 0, sizeof(msg));
    msg.payload = (const uint8_t*)"";
    msg.kind = NIMFFI_MSG_STALE_WARN;
    msg.id = 7;
    msg.aux = 5000;
    assert(my_timer_ctx_dispatch(ctx, &msg, &handlers) == 0);
    assert(my_timer_ctx_dispatch(ctx, &msg, NULL) == 0);
    assert(sink.stale_hits == 1);
    assert(my_timer_ctx_dispatch(NULL, &msg, &handlers) < 0);

    /* CLOSED settles whatever still waits, then tells the host. */
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {"orphan", 1};
    assert(my_timer_ctx_echo(ctx, &req, on_echo, &w, NULL) == NIMFFI_RET_OK);
    msg.kind = NIMFFI_MSG_CLOSED;
    msg.id = 0;
    msg.aux = 0;
    assert(my_timer_ctx_dispatch(ctx, &msg, &handlers) == 0);
    assert(w.done == 1 && w.ret == NIMFFI_RET_CLOSED);
    assert(strcmp(w.err, "context closed") == 0);
    assert(sink.closed_hits == 1 && ctx->pending.len == 0);
    /* The context is in fact alive: its event and its reply come out, to nobody. */
    while (my_timer_ctx_pump_once(ctx, 100, NULL) == NIMFFI_RET_OK) {
    }
    assert(w.done == 1);
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
    assert(my_timer_ctx_echo(ctx, &req, on_echo, &w, NULL) == NIMFFI_RET_OK);

    /* The event and the reply: the handle stays ready until both are out. */
    int taken = 0;
    while (taken < 2) {
        assert(wait_ready(handle, WAIT_LIMIT_MS));
        taken += drain(ctx, &handlers);
    }
    assert(taken == 2);
    assert(strcmp(sink.message, "fd") == 0);
    assert(w.done == 1 && w.ret == NIMFFI_RET_OK);
    /* Drained: the handle is quiet again. */
    assert(!wait_ready(handle, 0));
    close_handle(handle);
}

/* The handle outlives the context, the token does not. A request still waiting
 * is settled by the destroy, once, without a reply. */
static void test_destroy(MyTimerCtx* ctx) {
    intptr_t handle = my_timer_ctx_poll_fd(ctx);
    assert(handle != -1);
    void* token = ctx->ptr;

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    EchoRequest req = {"unanswered", 200};
    assert(my_timer_ctx_echo(ctx, &req, on_echo, &w, NULL) == NIMFFI_RET_OK);

    assert(my_timer_ctx_destroy(ctx) == NIMFFI_RET_OK);
    assert(w.done == 1 && w.ret == NIMFFI_RET_CLOSED);
    assert(strcmp(w.err, "context closed") == 0);

    const NimFfiMsg* msg = NULL;
    assert(my_timer_poll(token, 0, &msg) == NIMFFI_RET_INVALID_CTX);
    assert(msg == NULL);
    assert(my_timer_poll_fd(token) == -1);
    assert(my_timer_ctx_pump_once(NULL, 0, NULL) == NIMFFI_RET_INVALID_CTX);
    assert(my_timer_ctx_poll_fd(NULL) == -1);
    assert(my_timer_ctx_destroy(NULL) == NIMFFI_RET_OK);
    close_handle(handle);
}

int main(void) {
    MyTimerCtx* ctx = make_ctx();
    test_create_async();
    test_version(ctx);
    test_echo(ctx);
    test_echo_sync(ctx);
    test_complex(ctx);
    test_schedule_ok(ctx);
    test_schedule_error(ctx);
    test_sync_error(ctx);
    test_sync_timeout(ctx);
    test_in_flight(ctx);
    test_sync_among_async(ctx);
    test_sync_inside_handler(ctx);
    test_refused_submit();
    test_statics();
    test_ignored_event(ctx);
    test_raw(ctx);
    test_dispatch_liveness(ctx);
    test_poll_fd(ctx);
    test_destroy(ctx);
    assert(my_timer_shutdown() == NIMFFI_RET_OK);
    printf("all C e2e checks passed\n");
    return 0;
}
