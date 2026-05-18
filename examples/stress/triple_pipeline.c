/* Three-library pipeline:
 *   1. my_timer_echo("msg")              -> echoed = "msg"
 *   2. echoer_shout(echoed, "!!!")       -> shouted = "PIPE: msg!!!"
 *   3. aggregator_record(shouted)        -> stored, returns running count
 *   ... repeat N times, then aggregator_summarize() asserts count == N.
 *
 * Proves strings can flow from one nim-ffi library into another purely
 * through the pure-C ABI: each callback delivers a wire Resp whose
 * cstrings live in shared memory; we deep-copy them out before they're
 * freed, then plug them into the next library's wire Req.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sync_helper.h"
#include "my_timer.h"
#include "echoer.h"
#include "aggregator.h"

static const int ITERATIONS = 12;

/* ── callbacks ──────────────────────────────────────────────────────────── */

static void cb_ctor(int ret, const char* msg, size_t len, void* ud) {
    ffi_sync_t* s = (ffi_sync_t*)ud;
    s->ret = ret;
    if (ret != 0) ffi_sync_capture_err(s, msg, len);
    ffi_sync_signal(s);
}

static void cb_timer_echo(int ret, const char* msg, size_t len, void* ud) {
    ffi_sync_t* s = (ffi_sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && len >= sizeof(MyTimerEchoResp)) {
        const MyTimerEchoResp* r = (const MyTimerEchoResp*)msg;
        ffi_sync_copy_str(s->slot_str_a, sizeof(s->slot_str_a), r->value.echoed);
    } else if (ret != 0) ffi_sync_capture_err(s, msg, len);
    ffi_sync_signal(s);
}

static void cb_echoer_shout(int ret, const char* msg, size_t len, void* ud) {
    ffi_sync_t* s = (ffi_sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && len >= sizeof(EchoerShoutResp)) {
        const EchoerShoutResp* r = (const EchoerShoutResp*)msg;
        ffi_sync_copy_str(s->slot_str_a, sizeof(s->slot_str_a), r->value.shouted);
    } else if (ret != 0) ffi_sync_capture_err(s, msg, len);
    ffi_sync_signal(s);
}

static void cb_record(int ret, const char* msg, size_t len, void* ud) {
    ffi_sync_t* s = (ffi_sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && len >= sizeof(AggregatorRecordResp)) {
        const AggregatorRecordResp* r = (const AggregatorRecordResp*)msg;
        s->slot_int_a = (long)r->value.index;
        s->slot_int_b = (long)r->value.count;
    } else if (ret != 0) ffi_sync_capture_err(s, msg, len);
    ffi_sync_signal(s);
}

static void cb_summarize(int ret, const char* msg, size_t len, void* ud) {
    ffi_sync_t* s = (ffi_sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && len >= sizeof(AggregatorSummarizeResp)) {
        const AggregatorSummarizeResp* r = (const AggregatorSummarizeResp*)msg;
        s->slot_int_a = (long)r->value.count;
        s->slot_int_b = (long)r->value.entries_len;
    } else if (ret != 0) ffi_sync_capture_err(s, msg, len);
    ffi_sync_signal(s);
}

/* ── driver ────────────────────────────────────────────────────────────── */

int main(void) {
    ffi_sync_t s;

    /* Bring up all three libraries */
    ffi_sync_init(&s);
    TimerConfig tcfg = { .name = "pipe-timer" };
    MyTimerCreateCtorReq tcReq = { .config = tcfg };
    void* timer_ctx = my_timer_create(&tcReq, cb_ctor, &s);
    if (!timer_ctx) { ffi_sync_wait(&s); fprintf(stderr, "timer ctor: %s\n", s.err); return 1; }
    ffi_sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "timer ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    ffi_sync_init(&s);
    EchoerConfig ecfg = { .prefix = "PIPE" };
    EchoerCreateCtorReq ecReq = { .config = ecfg };
    void* echoer_ctx = echoer_create(&ecReq, cb_ctor, &s);
    if (!echoer_ctx) { ffi_sync_wait(&s); fprintf(stderr, "echoer ctor: %s\n", s.err); return 1; }
    ffi_sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "echoer ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    ffi_sync_init(&s);
    AggregatorConfig acfg = { .prefix = "agg" };
    AggregatorCreateCtorReq acReq = { .config = acfg };
    void* agg_ctx = aggregator_create(&acReq, cb_ctor, &s);
    if (!agg_ctx) { ffi_sync_wait(&s); fprintf(stderr, "agg ctor: %s\n", s.err); return 1; }
    ffi_sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "agg ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    printf("[ok] all three libraries up\n");

    /* Drive the pipeline N times */
    for (int i = 0; i < ITERATIONS; i++) {
        char msg[64];
        snprintf(msg, sizeof(msg), "msg-%d", i);

        /* timer step */
        ffi_sync_init(&s);
        EchoRequest er = { .message = msg, .delayMs = 0 };
        MyTimerEchoReq teReq = { .req = er };
        if (my_timer_echo(timer_ctx, cb_timer_echo, &s, &teReq) != 0) {
            fprintf(stderr, "timer dispatch failed at i=%d\n", i); return 1;
        }
        ffi_sync_wait(&s);
        if (s.ret != 0) { fprintf(stderr, "timer cb err: %s\n", s.err); return 1; }
        if (strcmp(s.slot_str_a, msg) != 0) {
            fprintf(stderr, "timer echo mismatch i=%d got=%s\n", i, s.slot_str_a);
            return 1;
        }
        char echoed[256];
        ffi_sync_copy_str(echoed, sizeof(echoed), s.slot_str_a);
        ffi_sync_destroy(&s);

        /* echoer step */
        ffi_sync_init(&s);
        ShoutRequest sr = { .message = echoed, .exclamations = 3 };
        EchoerShoutReq esReq = { .req = sr };
        if (echoer_shout(echoer_ctx, cb_echoer_shout, &s, &esReq) != 0) {
            fprintf(stderr, "echoer dispatch failed at i=%d\n", i); return 1;
        }
        ffi_sync_wait(&s);
        if (s.ret != 0) { fprintf(stderr, "echoer cb err: %s\n", s.err); return 1; }
        char shouted[256];
        ffi_sync_copy_str(shouted, sizeof(shouted), s.slot_str_a);
        ffi_sync_destroy(&s);

        /* expected: "PIPE: msg-i!!!" */
        char expected[256];
        snprintf(expected, sizeof(expected), "PIPE: msg-%d!!!", i);
        if (strcmp(shouted, expected) != 0) {
            fprintf(stderr, "shout mismatch i=%d got=%s want=%s\n",
                    i, shouted, expected);
            return 1;
        }

        /* aggregator step */
        ffi_sync_init(&s);
        RecordRequest rr = { .entry = shouted };
        AggregatorRecordReq arReq = { .req = rr };
        if (aggregator_record(agg_ctx, cb_record, &s, &arReq) != 0) {
            fprintf(stderr, "record dispatch failed at i=%d\n", i); return 1;
        }
        ffi_sync_wait(&s);
        if (s.ret != 0) { fprintf(stderr, "record cb err: %s\n", s.err); return 1; }
        if (s.slot_int_a != i || s.slot_int_b != i + 1) {
            fprintf(stderr, "record mismatch i=%d idx=%ld cnt=%ld\n",
                    i, s.slot_int_a, s.slot_int_b);
            return 1;
        }
        ffi_sync_destroy(&s);
    }
    printf("[ok] %d pipeline iterations\n", ITERATIONS);

    /* Final summary */
    ffi_sync_init(&s);
    AggregatorSummarizeReq sumReq = { 0 };
    aggregator_summarize(agg_ctx, cb_summarize, &s, &sumReq);
    ffi_sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "summary err: %s\n", s.err); return 1; }
    if (s.slot_int_a != ITERATIONS || s.slot_int_b != ITERATIONS) {
        fprintf(stderr, "summary mismatch count=%ld entries=%ld\n",
                s.slot_int_a, s.slot_int_b);
        return 1;
    }
    ffi_sync_destroy(&s);
    printf("[ok] final summary count=%d entries=%d\n", ITERATIONS, ITERATIONS);

    my_timer_destroy(timer_ctx);
    echoer_destroy(echoer_ctx);
    aggregator_destroy(agg_ctx);
    printf("[pass] triple-pipeline stress green\n");
    return 0;
}
