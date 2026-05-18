/* Multi-context parallelism stress.
 *
 * Brings up K independent aggregator contexts (each is a separate
 * libaggregator FFIContext, with its own background thread + state).
 * Spins up K host threads — one per context — and has each thread
 * record M messages into its own aggregator simultaneously. After
 * join, each aggregator is summarised; the test asserts:
 *
 *   - every context sees exactly its own M messages (no cross-talk),
 *   - the counter reaches M with no missing entries,
 *   - each context's prefix is intact (its own state is intact).
 *
 * Exercises:
 *   - lots of FFI contexts of the same library type alive at once,
 *   - per-context background threads + channels operating independently,
 *   - host-side concurrency through the pure-C ABI.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sync_helper.h"
#include "aggregator.h"

#define K_CONTEXTS 6
#define M_PER_CTX  40

/* ── callbacks ──────────────────────────────────────────────────────────── */

static void cb_ctor(int ret, const char* msg, size_t len, void* ud) {
    ffi_sync_t* s = (ffi_sync_t*)ud;
    s->ret = ret;
    if (ret != 0) ffi_sync_capture_err(s, msg, len);
    ffi_sync_signal(s);
}

static void cb_record(int ret, const char* msg, size_t len, void* ud) {
    ffi_sync_t* s = (ffi_sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && len >= sizeof(AggregatorRecordResp)) {
        const AggregatorRecordResp* r = (const AggregatorRecordResp*)msg;
        s->slot_int_a = (long)r->value.index;
        s->slot_int_b = (long)r->value.count;
        ffi_sync_copy_str(s->slot_str_a, sizeof(s->slot_str_a), r->value.prefix);
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
        ffi_sync_copy_str(s->slot_str_a, sizeof(s->slot_str_a), r->value.prefix);
    } else if (ret != 0) ffi_sync_capture_err(s, msg, len);
    ffi_sync_signal(s);
}

/* ── worker thread: records M messages into one aggregator ────────────── */

typedef struct {
    int   tid;
    void* ctx;
    char  prefix[64];
    int   failures;
} worker_arg_t;

static void* worker_main(void* arg) {
    worker_arg_t* w = (worker_arg_t*)arg;
    for (int i = 0; i < M_PER_CTX; i++) {
        char entry[64];
        snprintf(entry, sizeof(entry), "t%d-msg%d", w->tid, i);

        ffi_sync_t s;
        ffi_sync_init(&s);
        RecordRequest rr = { .entry = entry };
        AggregatorRecordReq req = { .req = rr };
        if (aggregator_record(w->ctx, cb_record, &s, &req) != 0) {
            w->failures++;
            ffi_sync_destroy(&s);
            return NULL;
        }
        ffi_sync_wait(&s);
        if (s.ret != 0) { w->failures++; ffi_sync_destroy(&s); return NULL; }
        if (s.slot_int_a != i) { /* index should match local iteration */
            fprintf(stderr, "t%d: index drift i=%d got=%ld\n", w->tid, i, s.slot_int_a);
            w->failures++;
        }
        if (strcmp(s.slot_str_a, w->prefix) != 0) {
            fprintf(stderr, "t%d: prefix drift got='%s' want='%s'\n",
                    w->tid, s.slot_str_a, w->prefix);
            w->failures++;
        }
        ffi_sync_destroy(&s);
    }
    return NULL;
}

/* ── driver ────────────────────────────────────────────────────────────── */

int main(void) {
    void* ctxs[K_CONTEXTS];
    char  prefixes[K_CONTEXTS][64];

    /* Bring up K aggregators */
    for (int k = 0; k < K_CONTEXTS; k++) {
        snprintf(prefixes[k], sizeof(prefixes[k]), "agg-%d", k);
        ffi_sync_t s;
        ffi_sync_init(&s);
        AggregatorConfig cfg = { .prefix = prefixes[k] };
        AggregatorCreateCtorReq req = { .config = cfg };
        ctxs[k] = aggregator_create(&req, cb_ctor, &s);
        if (!ctxs[k]) { ffi_sync_wait(&s); fprintf(stderr, "ctor[%d]: %s\n", k, s.err); return 1; }
        ffi_sync_wait(&s);
        if (s.ret != 0) { fprintf(stderr, "ctor[%d] err: %s\n", k, s.err); return 1; }
        ffi_sync_destroy(&s);
    }
    printf("[ok] spawned %d aggregator contexts\n", K_CONTEXTS);

    /* Spin up K host threads each pounding its own aggregator */
    pthread_t threads[K_CONTEXTS];
    worker_arg_t args[K_CONTEXTS];
    for (int k = 0; k < K_CONTEXTS; k++) {
        args[k].tid = k;
        args[k].ctx = ctxs[k];
        args[k].failures = 0;
        strncpy(args[k].prefix, prefixes[k], sizeof(args[k].prefix) - 1);
        args[k].prefix[sizeof(args[k].prefix) - 1] = '\0';
        if (pthread_create(&threads[k], NULL, worker_main, &args[k]) != 0) {
            fprintf(stderr, "pthread_create k=%d failed\n", k); return 1;
        }
    }
    for (int k = 0; k < K_CONTEXTS; k++) pthread_join(threads[k], NULL);

    int total_failures = 0;
    for (int k = 0; k < K_CONTEXTS; k++) total_failures += args[k].failures;
    if (total_failures != 0) {
        fprintf(stderr, "worker failures: %d\n", total_failures); return 1;
    }
    printf("[ok] %d threads × %d records each — no per-thread failures\n",
           K_CONTEXTS, M_PER_CTX);

    /* Summarise each context, assert isolation */
    for (int k = 0; k < K_CONTEXTS; k++) {
        ffi_sync_t s;
        ffi_sync_init(&s);
        AggregatorSummarizeReq req = { 0 };
        aggregator_summarize(ctxs[k], cb_summarize, &s, &req);
        ffi_sync_wait(&s);
        if (s.ret != 0) { fprintf(stderr, "summary[%d]: %s\n", k, s.err); return 1; }
        if (s.slot_int_a != M_PER_CTX || s.slot_int_b != M_PER_CTX) {
            fprintf(stderr, "summary[%d] mismatch: count=%ld entries=%ld\n",
                    k, s.slot_int_a, s.slot_int_b);
            return 1;
        }
        if (strcmp(s.slot_str_a, prefixes[k]) != 0) {
            fprintf(stderr, "summary[%d] prefix drift: got='%s' want='%s'\n",
                    k, s.slot_str_a, prefixes[k]);
            return 1;
        }
        ffi_sync_destroy(&s);
    }
    printf("[ok] all %d contexts summarised — independent state preserved\n",
           K_CONTEXTS);

    for (int k = 0; k < K_CONTEXTS; k++) aggregator_destroy(ctxs[k]);
    printf("[pass] multi-context stress green\n");
    return 0;
}
