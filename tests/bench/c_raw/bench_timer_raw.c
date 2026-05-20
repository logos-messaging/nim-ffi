// End-to-end FFI round-trip benchmark for the raw-mode timer library.
//
// Uses the auto-generated pure-C header at
// `examples/timer/c_bindings/my_timer.h`. There is no C++ sugar layer yet
// for raw mode (see meta.nim's readiness matrix), so this harness drives
// the FFI directly via pthread sync primitives.
//
// CSV output is identical in shape to `bench_timer_cbor.cpp` so the runner
// script can join the two streams.

#include "my_timer.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

// ── Synchronous wait helper ───────────────────────────────────────────────
// The FFI macros always dispatch to the FFI thread, so even sync-bodied
// procs come back via the callback. We deep-copy the response struct on
// the callback thread because the framework only guarantees the payload
// is live for the callback's duration.

typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t  cv;
    int             done;
    int             ok;
    void*           buf;
    size_t          buf_len;
    char            err[256];
} CallState;

static void cb_(int ret, const char* msg, size_t len, void* user_data) {
    CallState* s = (CallState*)user_data;
    pthread_mutex_lock(&s->mtx);
    s->ok = (ret == 0);
    if (s->ok) {
        if (msg && len > 0) {
            s->buf = malloc(len);
            memcpy(s->buf, msg, len);
            s->buf_len = len;
        }
    } else {
        size_t n = len < sizeof(s->err) - 1 ? len : sizeof(s->err) - 1;
        if (msg) memcpy(s->err, msg, n);
        s->err[n] = '\0';
    }
    s->done = 1;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mtx);
}

static void cs_init(CallState* s) {
    pthread_mutex_init(&s->mtx, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->done = 0; s->ok = 0; s->buf = NULL; s->buf_len = 0; s->err[0] = '\0';
}

static void cs_wait(CallState* s) {
    pthread_mutex_lock(&s->mtx);
    while (!s->done) pthread_cond_wait(&s->cv, &s->mtx);
    pthread_mutex_unlock(&s->mtx);
}

static void cs_destroy(CallState* s) {
    if (s->buf) { free(s->buf); s->buf = NULL; }
    pthread_mutex_destroy(&s->mtx);
    pthread_cond_destroy(&s->cv);
}

// ── Clock ────────────────────────────────────────────────────────────────
static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// ── Per-op drivers ───────────────────────────────────────────────────────

static void* g_ctx = NULL;

static void run_version(void) {
    MyTimerVersionReq req; memset(&req, 0, sizeof(req));
    CallState s; cs_init(&s);
    int ret = my_timer_version(g_ctx, cb_, &s, &req);
    if (ret != 0) { fprintf(stderr, "version returned %d\n", ret); exit(1); }
    cs_wait(&s);
    if (!s.ok) { fprintf(stderr, "version error: %s\n", s.err); exit(1); }
    cs_destroy(&s);
}

static void run_echo_0ms(void) {
    EchoRequest e = { .message = "hello", .delayMs = 0 };
    MyTimerEchoReq req = { .req = e };
    CallState s; cs_init(&s);
    int ret = my_timer_echo(g_ctx, cb_, &s, &req);
    if (ret != 0) { fprintf(stderr, "echo returned %d\n", ret); exit(1); }
    cs_wait(&s);
    if (!s.ok) { fprintf(stderr, "echo error: %s\n", s.err); exit(1); }
    const MyTimerEchoResp* r = (const MyTimerEchoResp*)s.buf;
    if (!r->value.timerName || strlen(r->value.timerName) == 0) abort();
    cs_destroy(&s);
}

static void run_complex_small(void) {
    EchoRequest msgs[4] = {
        { "alpha", 0 }, { "beta", 0 }, { "gamma", 0 }, { "delta", 0 },
    };
    const char* tags[3] = { "fast", "async", "bench" };
    const char* note_val = "a slightly longer note";
    int64_t retries_val = 7;
    ComplexRequest c = {
        .messages = msgs, .messages_len = 4,
        .tags = tags,     .tags_len = 3,
        .note = &note_val,
        .retries = &retries_val,
    };
    MyTimerComplexReq req = { .req = c };
    CallState s; cs_init(&s);
    int ret = my_timer_complex(g_ctx, cb_, &s, &req);
    if (ret != 0) { fprintf(stderr, "complex returned %d\n", ret); exit(1); }
    cs_wait(&s);
    if (!s.ok) { fprintf(stderr, "complex error: %s\n", s.err); exit(1); }
    const MyTimerComplexResp* r = (const MyTimerComplexResp*)s.buf;
    if (r->value.itemCount != 4) abort();
    cs_destroy(&s);
}

static const uint8_t* g_blob_buf = NULL;
static size_t g_blob_len = 0;

static void run_bytes_echo(void) {
    BytesPayload bp = { .payload = g_blob_buf, .payload_len = g_blob_len };
    MyTimerBytesEchoReq req = { .blob = bp };
    CallState s; cs_init(&s);
    int ret = my_timer_bytes_echo(g_ctx, cb_, &s, &req);
    if (ret != 0) { fprintf(stderr, "bytes_echo returned %d\n", ret); exit(1); }
    cs_wait(&s);
    if (!s.ok) { fprintf(stderr, "bytes_echo error: %s\n", s.err); exit(1); }
    const MyTimerBytesEchoResp* r = (const MyTimerBytesEchoResp*)s.buf;
    if (r->value.payload_len != g_blob_len) {
        fprintf(stderr, "bytes_echo len mismatch: got %zu want %zu\n",
                r->value.payload_len, g_blob_len);
        exit(1);
    }
    cs_destroy(&s);
}

static void run_schedule_3objs(void) {
    const char* payload[2] = { "rollup", "v2" };
    JobSpec job = { .name = "nightly-rollup",
                    .payload = payload, .payload_len = 2,
                    .priority = 10 };
    const char* retry_on[2] = { "timeout", "5xx" };
    RetryPolicy retry = { .maxAttempts = 3, .backoffMs = 500,
                          .retryOn = retry_on, .retryOn_len = 2 };
    int64_t jitter_val = 250;
    ScheduleConfig sched = { .startAtMs = 1000, .intervalMs = 15000,
                             .jitter = &jitter_val };
    MyTimerScheduleReq req = { .job = job, .retry = retry, .schedule = sched };
    CallState s; cs_init(&s);
    int ret = my_timer_schedule(g_ctx, cb_, &s, &req);
    if (ret != 0) { fprintf(stderr, "schedule returned %d\n", ret); exit(1); }
    cs_wait(&s);
    if (!s.ok) { fprintf(stderr, "schedule error: %s\n", s.err); exit(1); }
    const MyTimerScheduleResp* r = (const MyTimerScheduleResp*)s.buf;
    if (r->value.willRunCount <= 0) abort();
    cs_destroy(&s);
}

static void time_op(const char* label, int iters, void (*op)(void)) {
    int warm = iters < 50 ? iters : 50;
    for (int i = 0; i < warm; ++i) op();
    uint64_t start = now_ns();
    for (int i = 0; i < iters; ++i) op();
    uint64_t elapsed = now_ns() - start;
    double per_op = (double)elapsed / (double)iters;
    printf("%s,raw,%.2f,%d\n", label, per_op, iters);
    fflush(stdout);
}

int main(int argc, char** argv) {
    int version_iters = argc > 1 ? atoi(argv[1]) : 5000;
    int echo_iters    = argc > 2 ? atoi(argv[2]) : 2000;
    int complex_iters = argc > 3 ? atoi(argv[3]) : 2000;
    int sched_iters   = argc > 4 ? atoi(argv[4]) : 2000;

    // Bring up the context.
    TimerConfig cfg = { .name = "bench-raw" };
    MyTimerCreateCtorReq ctor_req = { .config = cfg };
    CallState s; cs_init(&s);
    g_ctx = my_timer_create(&ctor_req, cb_, &s);
    cs_wait(&s);
    if (!s.ok) { fprintf(stderr, "create error: %s\n", s.err); return 1; }
    cs_destroy(&s);
    if (!g_ctx) { fprintf(stderr, "create returned null ctx\n"); return 1; }

    printf("op,mode,ns_per_op,iters\n");
    time_op("version_sync",  version_iters, run_version);
    time_op("echo_0ms",      echo_iters,    run_echo_0ms);
    time_op("complex_small", complex_iters, run_complex_small);
    time_op("schedule_3objs", sched_iters,  run_schedule_3objs);

    // Payload-size sweep — same size points as the cbor harness.
    struct { int size; int iters; const char* label; } sweep[] = {
        {     100, 2000, "bytes_echo_100B"  },
        {    1024, 2000, "bytes_echo_1KiB"  },
        {  10*1024, 1000, "bytes_echo_10KiB" },
        {  64*1024,  500, "bytes_echo_64KiB" },
        { 150*1024,  300, "bytes_echo_150KiB"},
    };
    size_t sweep_n = sizeof(sweep) / sizeof(sweep[0]);
    for (size_t i = 0; i < sweep_n; ++i) {
        uint8_t* buf = (uint8_t*)malloc(sweep[i].size);
        memset(buf, 0xAB, sweep[i].size);
        g_blob_buf = buf;
        g_blob_len = sweep[i].size;
        time_op(sweep[i].label, sweep[i].iters, run_bytes_echo);
        free(buf);
        g_blob_buf = NULL;
        g_blob_len = 0;
    }

    my_timer_destroy(g_ctx);
    return 0;
}
