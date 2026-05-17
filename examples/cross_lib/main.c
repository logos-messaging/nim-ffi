/* Cross-library e2e for the pure-C target.
 *
 * Links **two** independently-built Nim-FFI shared libraries — libmy_timer
 * and libechoer — into a single process and walks a string from one
 * library to the other using only the generated pure-C ABIs (no CBOR, no
 * shared Nim runtime symbols). This is the in-process scenario that
 * justifies the C-target's existence: multiple Nim libraries cooperating
 * through a stable C boundary.
 *
 * Flow:
 *   1. Create a my_timer ctx (prefix "demo").
 *   2. Create an echoer ctx  (prefix "ECHO").
 *   3. Call my_timer_echo("relay", 1ms) → captures echoed = "relay".
 *   4. Feed that echoed string into echoer_shout(echoed, exclamations=3).
 *   5. Assert the echoer output is exactly "ECHO: relay!!!".
 *
 * Each library's callback signature is identical (`FfiCallback`) so the
 * same condvar-based sync helper drives both.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <assert.h>

#include "my_timer.h"
#include "echoer.h"

typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t  cv;
    int             done;
    int             ret;
    char            err[512];
    /* one buffer per relevant resp field; deep-copy out before returning. */
    char            field_a[256];
    char            field_b[256];
} sync_t;

static void sync_init(sync_t* s) {
    pthread_mutex_init(&s->mtx, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->done = 0;
    s->ret = -1;
    s->err[0] = '\0';
    s->field_a[0] = '\0';
    s->field_b[0] = '\0';
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

/* ── per-call callbacks ────────────────────────────────────────────────── */

static void cb_ctor(int ret, const char* msg, size_t len, void* ud) {
    sync_t* s = (sync_t*)ud;
    s->ret = ret;
    if (ret != 0) capture_err(s, msg, len);
    sync_signal(s);
}

static void cb_timer_echo(int ret, const char* msg, size_t len, void* ud) {
    sync_t* s = (sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && msg && len >= sizeof(MyTimerEchoResp)) {
        const MyTimerEchoResp* r = (const MyTimerEchoResp*)msg;
        if (r->value.echoed) {
            strncpy(s->field_a, r->value.echoed, sizeof(s->field_a) - 1);
            s->field_a[sizeof(s->field_a) - 1] = '\0';
        }
        if (r->value.timerName) {
            strncpy(s->field_b, r->value.timerName, sizeof(s->field_b) - 1);
            s->field_b[sizeof(s->field_b) - 1] = '\0';
        }
    } else if (ret != 0) {
        capture_err(s, msg, len);
    }
    sync_signal(s);
}

static void cb_echoer_shout(int ret, const char* msg, size_t len, void* ud) {
    sync_t* s = (sync_t*)ud;
    s->ret = ret;
    if (ret == 0 && msg && len >= sizeof(EchoerShoutResp)) {
        const EchoerShoutResp* r = (const EchoerShoutResp*)msg;
        if (r->value.shouted) {
            strncpy(s->field_a, r->value.shouted, sizeof(s->field_a) - 1);
            s->field_a[sizeof(s->field_a) - 1] = '\0';
        }
        if (r->value.prefixUsed) {
            strncpy(s->field_b, r->value.prefixUsed, sizeof(s->field_b) - 1);
            s->field_b[sizeof(s->field_b) - 1] = '\0';
        }
    } else if (ret != 0) {
        capture_err(s, msg, len);
    }
    sync_signal(s);
}

/* ── driver ────────────────────────────────────────────────────────────── */

int main(void) {
    sync_t s;

    /* 1. Bring up my_timer ──────────────────────────────────────────────── */
    sync_init(&s);
    TimerConfig tcfg = { .name = "demo" };
    MyTimerCreateCtorReq tCtorReq = { .config = tcfg };
    void* timer_ctx = my_timer_create(&tCtorReq, cb_ctor, &s);
    if (!timer_ctx) {
        sync_wait(&s);
        fprintf(stderr, "my_timer_create returned NULL: %s\n", s.err);
        return 1;
    }
    sync_wait(&s);
    if (s.ret != 0) {
        fprintf(stderr, "my_timer_create cb err (%d): %s\n", s.ret, s.err);
        return 1;
    }
    printf("[ok] my_timer ctx=%p\n", timer_ctx);

    /* 2. Bring up echoer ────────────────────────────────────────────────── */
    sync_init(&s);
    EchoerConfig ecfg = { .prefix = "ECHO" };
    EchoerCreateCtorReq eCtorReq = { .config = ecfg };
    void* echoer_ctx = echoer_create(&eCtorReq, cb_ctor, &s);
    if (!echoer_ctx) {
        sync_wait(&s);
        fprintf(stderr, "echoer_create returned NULL: %s\n", s.err);
        return 1;
    }
    sync_wait(&s);
    if (s.ret != 0) {
        fprintf(stderr, "echoer_create cb err (%d): %s\n", s.ret, s.err);
        return 1;
    }
    printf("[ok] echoer ctx=%p\n", echoer_ctx);

    /* 3. timer echoes a string ──────────────────────────────────────────── */
    sync_init(&s);
    EchoRequest er = { .message = "relay", .delayMs = 1 };
    MyTimerEchoReq teReq = { .req = er };
    int rc = my_timer_echo(timer_ctx, cb_timer_echo, &s, &teReq);
    if (rc != 0) {
        fprintf(stderr, "my_timer_echo dispatch failed rc=%d\n", rc);
        return 1;
    }
    sync_wait(&s);
    if (s.ret != 0) {
        fprintf(stderr, "my_timer_echo cb err (%d): %s\n", s.ret, s.err);
        return 1;
    }
    if (strcmp(s.field_a, "relay") != 0 || strcmp(s.field_b, "demo") != 0) {
        fprintf(stderr, "timer echo content mismatch: echoed='%s' timerName='%s'\n",
                s.field_a, s.field_b);
        return 1;
    }
    printf("[ok] my_timer_echo -> echoed='%s' timerName='%s'\n",
           s.field_a, s.field_b);

    /* 4. feed timer's echoed string into echoer ─────────────────────────── */
    char relayed[256];
    strncpy(relayed, s.field_a, sizeof(relayed) - 1);
    relayed[sizeof(relayed) - 1] = '\0';

    sync_init(&s);
    ShoutRequest sr = { .message = relayed, .exclamations = 3 };
    EchoerShoutReq esReq = { .req = sr };
    rc = echoer_shout(echoer_ctx, cb_echoer_shout, &s, &esReq);
    if (rc != 0) {
        fprintf(stderr, "echoer_shout dispatch failed rc=%d\n", rc);
        return 1;
    }
    sync_wait(&s);
    if (s.ret != 0) {
        fprintf(stderr, "echoer_shout cb err (%d): %s\n", s.ret, s.err);
        return 1;
    }
    printf("[ok] echoer_shout -> shouted='%s' prefixUsed='%s'\n",
           s.field_a, s.field_b);

    if (strcmp(s.field_a, "ECHO: relay!!!") != 0) {
        fprintf(stderr, "echoer output mismatch — expected 'ECHO: relay!!!'\n");
        return 1;
    }
    if (strcmp(s.field_b, "ECHO") != 0) {
        fprintf(stderr, "echoer prefix mismatch\n");
        return 1;
    }

    /* 5. tear down both ─────────────────────────────────────────────────── */
    int trc = my_timer_destroy(timer_ctx);
    int erc = echoer_destroy(echoer_ctx);
    if (trc != 0 || erc != 0) {
        fprintf(stderr, "destroy failed: timer=%d echoer=%d\n", trc, erc);
        return 1;
    }
    printf("[ok] both contexts destroyed\n");

    printf("[pass] cross-library smoke green\n");
    return 0;
}
