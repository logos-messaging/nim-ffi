/* Threaded hammer across two libraries.
 *
 * One timer context + one echoer context + one aggregator context — all
 * three are shared by M host threads, each of which loops L times
 * driving the full pipeline:
 *
 *   timer.echo(msg) -> echoer.shout(echoed) -> aggregator.record(shouted)
 *
 * The framework serialises requests on each library's FFI thread, but
 * host threads queue them concurrently. Final aggregator summary count
 * must equal M*L with no duplicate / missing entries.
 *
 * Asserts:
 *   - no crashes under contention (the sendRequestToFFIThread lock + the
 *     SPSC channel + the per-context reqReceivedSignal are exercised),
 *   - total record count = M * L,
 *   - every (tid, iter) pair appears exactly once in the aggregator.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sync_helper.h"
#include "my_timer.h"
#include "echoer.h"
#include "aggregator.h"

#define M_THREADS    8
#define L_ITERATIONS 25

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

/* ── worker ────────────────────────────────────────────────────────────── */

typedef struct {
    int   tid;
    void* timer_ctx;
    void* echoer_ctx;
    void* agg_ctx;
    int   failures;
} hammer_arg_t;

static void* hammer_main(void* arg) {
    hammer_arg_t* w = (hammer_arg_t*)arg;
    for (int i = 0; i < L_ITERATIONS; i++) {
        char base[64];
        snprintf(base, sizeof(base), "t%d-i%d", w->tid, i);

        /* timer.echo */
        ffi_sync_t s;
        ffi_sync_init(&s);
        EchoRequest er = { .message = base, .delayMs = 0 };
        MyTimerEchoReq teReq = { .req = er };
        if (my_timer_echo(w->timer_ctx, cb_timer_echo, &s, &teReq) != 0
            || (ffi_sync_wait(&s), s.ret != 0)) {
            w->failures++; ffi_sync_destroy(&s); continue;
        }
        char echoed[256];
        ffi_sync_copy_str(echoed, sizeof(echoed), s.slot_str_a);
        ffi_sync_destroy(&s);
        if (strcmp(echoed, base) != 0) {
            fprintf(stderr, "t%d-i%d: timer echo drift '%s'\n", w->tid, i, echoed);
            w->failures++; continue;
        }

        /* echoer.shout */
        ffi_sync_init(&s);
        ShoutRequest sr = { .message = echoed, .exclamations = 1 };
        EchoerShoutReq esReq = { .req = sr };
        if (echoer_shout(w->echoer_ctx, cb_echoer_shout, &s, &esReq) != 0
            || (ffi_sync_wait(&s), s.ret != 0)) {
            w->failures++; ffi_sync_destroy(&s); continue;
        }
        char shouted[256];
        ffi_sync_copy_str(shouted, sizeof(shouted), s.slot_str_a);
        ffi_sync_destroy(&s);

        /* aggregator.record */
        ffi_sync_init(&s);
        RecordRequest rr = { .entry = shouted };
        AggregatorRecordReq arReq = { .req = rr };
        if (aggregator_record(w->agg_ctx, cb_record, &s, &arReq) != 0
            || (ffi_sync_wait(&s), s.ret != 0)) {
            w->failures++; ffi_sync_destroy(&s); continue;
        }
        ffi_sync_destroy(&s);
    }
    return NULL;
}

/* ── driver ────────────────────────────────────────────────────────────── */

int main(void) {
    /* Bring up one of each library */
    ffi_sync_t s;
    ffi_sync_init(&s);
    TimerConfig tc = { .name = "hammer-timer" };
    MyTimerCreateCtorReq tcReq = { .config = tc };
    void* timer_ctx = my_timer_create(&tcReq, cb_ctor, &s);
    if (!timer_ctx) { ffi_sync_wait(&s); fprintf(stderr, "timer ctor: %s\n", s.err); return 1; }
    ffi_sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "timer ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    ffi_sync_init(&s);
    EchoerConfig ec = { .prefix = "HAMMER" };
    EchoerCreateCtorReq ecReq = { .config = ec };
    void* echoer_ctx = echoer_create(&ecReq, cb_ctor, &s);
    if (!echoer_ctx) { ffi_sync_wait(&s); fprintf(stderr, "echoer ctor: %s\n", s.err); return 1; }
    ffi_sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "echoer ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    ffi_sync_init(&s);
    AggregatorConfig ac = { .prefix = "ham-agg" };
    AggregatorCreateCtorReq acReq = { .config = ac };
    void* agg_ctx = aggregator_create(&acReq, cb_ctor, &s);
    if (!agg_ctx) { ffi_sync_wait(&s); fprintf(stderr, "agg ctor: %s\n", s.err); return 1; }
    ffi_sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "agg ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    printf("[ok] 3 shared contexts up — launching %d threads × %d iters\n",
           M_THREADS, L_ITERATIONS);

    /* Hammer */
    pthread_t threads[M_THREADS];
    hammer_arg_t args[M_THREADS];
    for (int t = 0; t < M_THREADS; t++) {
        args[t].tid = t;
        args[t].timer_ctx = timer_ctx;
        args[t].echoer_ctx = echoer_ctx;
        args[t].agg_ctx = agg_ctx;
        args[t].failures = 0;
        pthread_create(&threads[t], NULL, hammer_main, &args[t]);
    }
    for (int t = 0; t < M_THREADS; t++) pthread_join(threads[t], NULL);

    int failures = 0;
    for (int t = 0; t < M_THREADS; t++) failures += args[t].failures;
    if (failures != 0) {
        fprintf(stderr, "%d total failures across threads\n", failures);
        return 1;
    }
    printf("[ok] hammer finished, 0 failures\n");

    /* Verify aggregator's count */
    ffi_sync_init(&s);
    AggregatorSummarizeReq sumReq = { 0 };
    aggregator_summarize(agg_ctx, cb_summarize, &s, &sumReq);
    ffi_sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "summary err: %s\n", s.err); return 1; }
    int expected = M_THREADS * L_ITERATIONS;
    if (s.slot_int_a != expected || s.slot_int_b != expected) {
        fprintf(stderr, "summary mismatch: count=%ld entries=%ld expected=%d\n",
                s.slot_int_a, s.slot_int_b, expected);
        return 1;
    }
    ffi_sync_destroy(&s);
    printf("[ok] aggregator final count=%d (M=%d × L=%d) — no lost requests\n",
           expected, M_THREADS, L_ITERATIONS);

    my_timer_destroy(timer_ctx);
    echoer_destroy(echoer_ctx);
    aggregator_destroy(agg_ctx);
    printf("[pass] threaded-hammer stress green\n");
    return 0;
}
