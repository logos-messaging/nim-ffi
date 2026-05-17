/* End-to-end smoke for the pure-C target of nim-ffi.
 *
 * Builds against libmy_timer (Nim-built shared lib) using the generated
 * <my_timer.h> header. Exercises:
 *   - my_timer_create  (ctor: takes a TimerConfig, returns void* ctx)
 *   - my_timer_version (method: no params, returns string)
 *   - my_timer_echo    (method: takes EchoRequest, returns EchoResponse)
 *   - my_timer_destroy (dtor: cleans up)
 *
 * Each async call signals completion via a pthread mutex+condvar pair so
 * the test runs synchronously. The callback's `msg` is cast to the
 * relevant `const <Proc>Resp*` and its fields read before the callback
 * returns (per the lifetime contract documented in the header).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <assert.h>

#include "my_timer.h"

typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t  cv;
    int             done;
    int             ret;
    char            err[512];
    /* Captured response — caller deep-copies what it needs before the
     * callback returns. */
    char            version_str[256];
    char            echo_echoed[256];
    char            echo_timer_name[256];
} cb_state_t;

static void cb_state_init(cb_state_t* s) {
    pthread_mutex_init(&s->mtx, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->done = 0;
    s->ret = -1;
    s->err[0] = '\0';
    s->version_str[0] = '\0';
    s->echo_echoed[0] = '\0';
    s->echo_timer_name[0] = '\0';
}

static void cb_state_wait(cb_state_t* s) {
    pthread_mutex_lock(&s->mtx);
    while (!s->done) {
        pthread_cond_wait(&s->cv, &s->mtx);
    }
    pthread_mutex_unlock(&s->mtx);
}

static void cb_state_signal_done(cb_state_t* s) {
    pthread_mutex_lock(&s->mtx);
    s->done = 1;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mtx);
}

/* ── callbacks ──────────────────────────────────────────────────────────── */

static void on_create(int ret, const char* msg, size_t len, void* ud) {
    cb_state_t* s = (cb_state_t*)ud;
    s->ret = ret;
    if (ret != 0 && msg && len > 0) {
        size_t n = len < sizeof(s->err) - 1 ? len : sizeof(s->err) - 1;
        memcpy(s->err, msg, n);
        s->err[n] = '\0';
    }
    cb_state_signal_done(s);
}

static void on_version(int ret, const char* msg, size_t len, void* ud) {
    cb_state_t* s = (cb_state_t*)ud;
    s->ret = ret;
    if (ret == 0 && msg && len >= sizeof(MyTimerVersionResp)) {
        const MyTimerVersionResp* r = (const MyTimerVersionResp*)msg;
        if (r->value) {
            strncpy(s->version_str, r->value, sizeof(s->version_str) - 1);
            s->version_str[sizeof(s->version_str) - 1] = '\0';
        }
    } else if (ret != 0 && msg && len > 0) {
        size_t n = len < sizeof(s->err) - 1 ? len : sizeof(s->err) - 1;
        memcpy(s->err, msg, n);
        s->err[n] = '\0';
    }
    cb_state_signal_done(s);
}

static void on_echo(int ret, const char* msg, size_t len, void* ud) {
    cb_state_t* s = (cb_state_t*)ud;
    s->ret = ret;
    if (ret == 0 && msg && len >= sizeof(MyTimerEchoResp)) {
        const MyTimerEchoResp* r = (const MyTimerEchoResp*)msg;
        if (r->value.echoed) {
            strncpy(s->echo_echoed, r->value.echoed, sizeof(s->echo_echoed) - 1);
            s->echo_echoed[sizeof(s->echo_echoed) - 1] = '\0';
        }
        if (r->value.timerName) {
            strncpy(s->echo_timer_name, r->value.timerName, sizeof(s->echo_timer_name) - 1);
            s->echo_timer_name[sizeof(s->echo_timer_name) - 1] = '\0';
        }
    } else if (ret != 0 && msg && len > 0) {
        size_t n = len < sizeof(s->err) - 1 ? len : sizeof(s->err) - 1;
        memcpy(s->err, msg, n);
        s->err[n] = '\0';
    }
    cb_state_signal_done(s);
}

/* ── test driver ────────────────────────────────────────────────────────── */

int main(void) {
    /* ── ctor ─────────────────────────────────────────────────────────── */
    cb_state_t state;
    cb_state_init(&state);

    TimerConfig cfg = { .name = "demo" };
    MyTimerCreateCtorReq creq = { .config = cfg };
    void* ctx = my_timer_create(&creq, on_create, &state);
    if (ctx == NULL) {
        cb_state_wait(&state);
        fprintf(stderr, "my_timer_create failed: %s\n", state.err);
        return 1;
    }
    cb_state_wait(&state);
    if (state.ret != 0) {
        fprintf(stderr, "my_timer_create callback err (%d): %s\n", state.ret, state.err);
        return 1;
    }
    printf("[ok] my_timer_create -> ctx=%p\n", ctx);

    /* ── version ──────────────────────────────────────────────────────── */
    cb_state_init(&state);
    MyTimerVersionReq vreq = { 0 };
    int rc = my_timer_version(ctx, on_version, &state, &vreq);
    if (rc != 0) {
        fprintf(stderr, "my_timer_version dispatch failed rc=%d\n", rc);
        return 1;
    }
    cb_state_wait(&state);
    if (state.ret != 0) {
        fprintf(stderr, "version cb err (%d): %s\n", state.ret, state.err);
        return 1;
    }
    printf("[ok] my_timer_version -> %s\n", state.version_str);
    if (strcmp(state.version_str, "nim-timer v0.1.0") != 0) {
        fprintf(stderr, "version string mismatch\n");
        return 1;
    }

    /* ── echo ─────────────────────────────────────────────────────────── */
    cb_state_init(&state);
    EchoRequest er = { .message = "hello from C", .delayMs = 1 };
    MyTimerEchoReq ereq = { .req = er };
    rc = my_timer_echo(ctx, on_echo, &state, &ereq);
    if (rc != 0) {
        fprintf(stderr, "my_timer_echo dispatch failed rc=%d\n", rc);
        return 1;
    }
    cb_state_wait(&state);
    if (state.ret != 0) {
        fprintf(stderr, "echo cb err (%d): %s\n", state.ret, state.err);
        return 1;
    }
    printf("[ok] my_timer_echo -> echoed='%s' timerName='%s'\n",
           state.echo_echoed, state.echo_timer_name);
    if (strcmp(state.echo_echoed, "hello from C") != 0) {
        fprintf(stderr, "echo content mismatch\n");
        return 1;
    }
    if (strcmp(state.echo_timer_name, "demo") != 0) {
        fprintf(stderr, "timer name mismatch\n");
        return 1;
    }

    /* ── dtor ─────────────────────────────────────────────────────────── */
    int drc = my_timer_destroy(ctx);
    if (drc != 0) {
        fprintf(stderr, "my_timer_destroy failed rc=%d\n", drc);
        return 1;
    }
    printf("[ok] my_timer_destroy\n");

    printf("[pass] all smoke checks green\n");
    return 0;
}
