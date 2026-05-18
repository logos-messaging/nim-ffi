/* Error-isolation stress.
 *
 * Three libraries live in one process. We deliberately inject bad input
 * into one library (aggregator's record with an empty string returns an
 * error from inside its .ffi. body) and assert that:
 *
 *   1. The error is reported via the callback's RET_ERR / msg path with
 *      the exact error string produced by Nim.
 *   2. The same aggregator context remains usable for subsequent valid
 *      calls (counter resumes from where it was, no state corruption).
 *   3. The other two libraries (timer + echoer) are unaffected — they
 *      keep producing the right responses interleaved with the bad
 *      aggregator calls.
 *
 * This is the "blast radius" check: an error inside one .ffi. body must
 * never propagate across library boundaries.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>

#include "sync_helper.h"
#include "my_timer.h"
#include "echoer.h"
#include "aggregator.h"

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

int main(void) {
    ffi_sync_t s;

    /* Bring up all three */
    ffi_sync_init(&s);
    TimerConfig tc = { .name = "iso-timer" };
    MyTimerCreateCtorReq tcReq = { .config = tc };
    void* timer_ctx = my_timer_create(&tcReq, cb_ctor, &s);
    ffi_sync_wait(&s);
    if (!timer_ctx || s.ret != 0) { fprintf(stderr, "timer ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    ffi_sync_init(&s);
    EchoerConfig ec = { .prefix = "ISO" };
    EchoerCreateCtorReq ecReq = { .config = ec };
    void* echoer_ctx = echoer_create(&ecReq, cb_ctor, &s);
    ffi_sync_wait(&s);
    if (!echoer_ctx || s.ret != 0) { fprintf(stderr, "echoer ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    ffi_sync_init(&s);
    AggregatorConfig ac = { .prefix = "iso-agg" };
    AggregatorCreateCtorReq acReq = { .config = ac };
    void* agg_ctx = aggregator_create(&acReq, cb_ctor, &s);
    ffi_sync_wait(&s);
    if (!agg_ctx || s.ret != 0) { fprintf(stderr, "agg ctor: %s\n", s.err); return 1; }
    ffi_sync_destroy(&s);

    /* Interleave good and bad aggregator calls, while running healthy
     * timer + echoer calls between them. Pattern: G, B, G, B, G, B, G
     * (4 good calls, 3 bad). */
    int good_count = 0;
    for (int i = 0; i < 7; i++) {
        const bool is_bad = (i % 2 == 1);

        /* timer + echoer are always healthy */
        ffi_sync_init(&s);
        char inputMsg[32];
        snprintf(inputMsg, sizeof(inputMsg), "iso-%d", i);
        EchoRequest er = { .message = inputMsg, .delayMs = 0 };
        MyTimerEchoReq teReq = { .req = er };
        my_timer_echo(timer_ctx, cb_timer_echo, &s, &teReq);
        ffi_sync_wait(&s);
        if (s.ret != 0 || strcmp(s.slot_str_a, inputMsg) != 0) {
            fprintf(stderr, "timer corrupted at i=%d: got='%s'\n", i, s.slot_str_a);
            return 1;
        }
        char echoed[64];
        ffi_sync_copy_str(echoed, sizeof(echoed), s.slot_str_a);
        ffi_sync_destroy(&s);

        ffi_sync_init(&s);
        ShoutRequest sr = { .message = echoed, .exclamations = 0 };
        EchoerShoutReq esReq = { .req = sr };
        echoer_shout(echoer_ctx, cb_echoer_shout, &s, &esReq);
        ffi_sync_wait(&s);
        if (s.ret != 0) {
            fprintf(stderr, "echoer corrupted at i=%d: %s\n", i, s.err);
            return 1;
        }
        char want_shout[64];
        snprintf(want_shout, sizeof(want_shout), "ISO: %s", echoed);
        if (strcmp(s.slot_str_a, want_shout) != 0) {
            fprintf(stderr, "echoer drift at i=%d: got='%s' want='%s'\n",
                    i, s.slot_str_a, want_shout);
            return 1;
        }
        ffi_sync_destroy(&s);

        /* aggregator: alternate good vs empty (bad) */
        ffi_sync_init(&s);
        const char* entry = is_bad ? "" : inputMsg;
        RecordRequest rr = { .entry = entry };
        AggregatorRecordReq arReq = { .req = rr };
        aggregator_record(agg_ctx, cb_record, &s, &arReq);
        ffi_sync_wait(&s);
        if (is_bad) {
            if (s.ret == 0) {
                fprintf(stderr, "i=%d: expected error on empty entry\n", i);
                return 1;
            }
            if (strcmp(s.err, "entry must not be empty") != 0) {
                fprintf(stderr, "i=%d: wrong err string: %s\n", i, s.err);
                return 1;
            }
        } else {
            if (s.ret != 0) {
                fprintf(stderr, "i=%d: unexpected error: %s\n", i, s.err);
                return 1;
            }
            if (s.slot_int_b != good_count + 1) {
                fprintf(stderr, "i=%d: counter drift cnt=%ld expected=%d\n",
                        i, s.slot_int_b, good_count + 1);
                return 1;
            }
            good_count++;
        }
        ffi_sync_destroy(&s);
    }
    printf("[ok] interleaved 4 good + 3 bad aggregator calls; "
           "timer+echoer unaffected throughout\n");

    /* Final summary: aggregator should have exactly good_count entries */
    ffi_sync_init(&s);
    AggregatorSummarizeReq sumReq = { 0 };
    aggregator_summarize(agg_ctx, cb_summarize, &s, &sumReq);
    ffi_sync_wait(&s);
    if (s.ret != 0 || s.slot_int_a != good_count || s.slot_int_b != good_count) {
        fprintf(stderr, "summary mismatch: count=%ld entries=%ld expected=%d\n",
                s.slot_int_a, s.slot_int_b, good_count);
        return 1;
    }
    ffi_sync_destroy(&s);
    printf("[ok] aggregator final count=%d (bad calls produced no state change)\n",
           good_count);

    my_timer_destroy(timer_ctx);
    echoer_destroy(echoer_ctx);
    aggregator_destroy(agg_ctx);
    printf("[pass] error-isolation stress green\n");
    return 0;
}
