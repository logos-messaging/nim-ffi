/* Single-library smoke for the aggregator example.
 *
 * Aggregator is the first stateful example library — each `record` call
 * mutates the in-memory history. This test exercises:
 *   - ctor / dtor for a ref-object library
 *   - mutation that survives across {.ffi.} method calls
 *   - seq[string] field on the response side (summarize.entries)
 *   - error path from inside an .ffi. body (empty entry rejected)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include "aggregator.h"

typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t  cv;
    int             done;
    int             ret;
    char            err[256];
    /* captured fields */
    long            index;
    long            count;
    char            prefix[128];
    /* for summarize */
    int             sum_count;
    int             sum_entries;
    char            first_entry[128];
} sync_t;

static void sync_init(sync_t* s) {
    pthread_mutex_init(&s->mtx, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->done = 0; s->ret = -1;
    s->err[0] = s->prefix[0] = s->first_entry[0] = '\0';
    s->index = s->count = -1;
    s->sum_count = s->sum_entries = -1;
}
static void sync_wait(sync_t* s) {
    pthread_mutex_lock(&s->mtx);
    while (!s->done) pthread_cond_wait(&s->cv, &s->mtx);
    pthread_mutex_unlock(&s->mtx);
}
static void sync_signal(sync_t* s) {
    pthread_mutex_lock(&s->mtx);
    s->done = 1;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mtx);
}
static void capture_err(sync_t* s, const char* msg, size_t len) {
    if (!msg || len == 0) return;
    size_t n = len < sizeof(s->err) - 1 ? len : sizeof(s->err) - 1;
    memcpy(s->err, msg, n);
    s->err[n] = '\0';
}

static void cb_ctor(int ret, const char* msg, size_t len, void* ud) {
    sync_t* s = (sync_t*)ud;
    s->ret = ret;
    if (ret != 0) capture_err(s, msg, len);
    sync_signal(s);
}

static void cb_record(int ret, const char* msg, size_t len, void* ud) {
    sync_t* s = (sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && msg && len >= sizeof(AggregatorRecordResp)) {
        const AggregatorRecordResp* r = (const AggregatorRecordResp*)msg;
        s->index = r->value.index;
        s->count = r->value.count;
        if (r->value.prefix) {
            strncpy(s->prefix, r->value.prefix, sizeof(s->prefix) - 1);
            s->prefix[sizeof(s->prefix) - 1] = '\0';
        }
    } else if (ret != 0) {
        capture_err(s, msg, len);
    }
    sync_signal(s);
}

static void cb_summarize(int ret, const char* msg, size_t len, void* ud) {
    sync_t* s = (sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && msg && len >= sizeof(AggregatorSummarizeResp)) {
        const AggregatorSummarizeResp* r = (const AggregatorSummarizeResp*)msg;
        s->sum_count = (int)r->value.count;
        s->sum_entries = (int)r->value.entries_len;
        if (r->value.entries_len > 0 && r->value.entries && r->value.entries[0]) {
            strncpy(s->first_entry, r->value.entries[0],
                    sizeof(s->first_entry) - 1);
            s->first_entry[sizeof(s->first_entry) - 1] = '\0';
        }
        if (r->value.prefix) {
            strncpy(s->prefix, r->value.prefix, sizeof(s->prefix) - 1);
            s->prefix[sizeof(s->prefix) - 1] = '\0';
        }
    } else if (ret != 0) {
        capture_err(s, msg, len);
    }
    sync_signal(s);
}

int main(void) {
    sync_t s;

    /* ctor */
    sync_init(&s);
    AggregatorConfig cfg = { .prefix = "agg-A" };
    AggregatorCreateCtorReq creq = { .config = cfg };
    void* ctx = aggregator_create(&creq, cb_ctor, &s);
    if (!ctx) {
        sync_wait(&s);
        fprintf(stderr, "aggregator_create returned NULL: %s\n", s.err);
        return 1;
    }
    sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "ctor err: %s\n", s.err); return 1; }
    printf("[ok] aggregator ctx=%p\n", ctx);

    /* record three entries */
    const char* msgs[] = { "alpha", "beta", "gamma" };
    for (int i = 0; i < 3; i++) {
        sync_init(&s);
        RecordRequest rr = { .entry = msgs[i] };
        AggregatorRecordReq req = { .req = rr };
        int rc = aggregator_record(ctx, cb_record, &s, &req);
        if (rc != 0) { fprintf(stderr, "record dispatch rc=%d\n", rc); return 1; }
        sync_wait(&s);
        if (s.ret != 0) { fprintf(stderr, "record cb err: %s\n", s.err); return 1; }
        if (s.index != i || s.count != i + 1 || strcmp(s.prefix, "agg-A") != 0) {
            fprintf(stderr, "record[%d] mismatch: idx=%ld cnt=%ld prefix=%s\n",
                    i, s.index, s.count, s.prefix);
            return 1;
        }
    }
    printf("[ok] recorded 3 entries\n");

    /* error path: empty entry */
    sync_init(&s);
    RecordRequest badrr = { .entry = "" };
    AggregatorRecordReq badreq = { .req = badrr };
    aggregator_record(ctx, cb_record, &s, &badreq);
    sync_wait(&s);
    if (s.ret == 0) { fprintf(stderr, "expected error on empty entry\n"); return 1; }
    if (strcmp(s.err, "entry must not be empty") != 0) {
        fprintf(stderr, "wrong error msg: %s\n", s.err); return 1;
    }
    printf("[ok] empty entry rejected: %s\n", s.err);

    /* summarize */
    sync_init(&s);
    AggregatorSummarizeReq sreq = { 0 };
    aggregator_summarize(ctx, cb_summarize, &s, &sreq);
    sync_wait(&s);
    if (s.ret != 0) { fprintf(stderr, "summ cb err: %s\n", s.err); return 1; }
    if (s.sum_count != 3 || s.sum_entries != 3) {
        fprintf(stderr, "summary mismatch: count=%d entries=%d\n",
                s.sum_count, s.sum_entries);
        return 1;
    }
    if (strcmp(s.first_entry, "alpha") != 0) {
        fprintf(stderr, "first entry mismatch: %s\n", s.first_entry); return 1;
    }
    if (strcmp(s.prefix, "agg-A") != 0) {
        fprintf(stderr, "prefix mismatch: %s\n", s.prefix); return 1;
    }
    printf("[ok] summarize -> count=%d entries=%d first='%s' prefix='%s'\n",
           s.sum_count, s.sum_entries, s.first_entry, s.prefix);

    int rc = aggregator_destroy(ctx);
    if (rc != 0) { fprintf(stderr, "destroy rc=%d\n", rc); return 1; }
    printf("[pass] aggregator smoke green\n");
    return 0;
}
