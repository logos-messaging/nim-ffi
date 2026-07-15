/* End-to-end test for the CBOR-free `abi = c` echo bindings: the `_CWire`
 * structs in echo.h are the C ABI, strings are borrowed `const char*`, no
 * TinyCBOR. Drives the async callback-per-call surface (ctor, object-returning
 * method, teardown). echoVersion rides the scalar fast path (no foreign binding
 * yet) and isn't exercised. */
#include "echo.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* The `done` flag is a C11 atomic: the callback fires on the FFI thread and
 * stores it with release ordering after filling the waiter's fields, and the
 * poller loads it with acquire ordering — so the field writes are visible
 * (and race-free under TSan) once `done` is seen set. */
static void wait_done(atomic_int* done) {
    for (int i = 0; i < 500 && !atomic_load_explicit(done, memory_order_acquire); i++) {
        struct timespec t = {0, 10 * 1000 * 1000}; /* 10ms */
        nanosleep(&t, NULL);
    }
    assert(atomic_load_explicit(done, memory_order_acquire));
}

typedef struct {
    atomic_int done;
    int err_code;
    EchoCtx* ctx;
    char err[256];
} CreateWaiter;

static void on_created(int ec, EchoCtx* ctx, const char* em, void* ud) {
    CreateWaiter* w = (CreateWaiter*)ud;
    w->err_code = ec;
    w->ctx = ctx;
    if (em) {
        snprintf(w->err, sizeof(w->err), "%s", em);
    }
    atomic_store_explicit(&w->done, 1, memory_order_release);
}

static EchoCtx* make_ctx(void) {
    CreateWaiter w;
    memset(&w, 0, sizeof(w));
    EchoConfig config = {"c-abi"};
    echo_ctx_create(&config, on_created, &w);
    wait_done(&w.done);
    if (w.err_code != 0) {
        fprintf(stderr, "create failed: %s\n", w.err[0] ? w.err : "?");
    }
    assert(w.err_code == 0);
    assert(w.ctx != NULL);
    return w.ctx;
}

typedef struct {
    atomic_int done;
    int err_code;
    char err[256];
    char text_a[256];
    char text_b[256];
} ReplyWaiter;

static void on_shout(int ec, const ShoutResponse* reply, const char* em, void* ud) {
    ReplyWaiter* w = (ReplyWaiter*)ud;
    w->err_code = ec;
    if (reply) {
        if (reply->shouted)
            snprintf(w->text_a, sizeof(w->text_a), "%s", reply->shouted);
        if (reply->prefix)
            snprintf(w->text_b, sizeof(w->text_b), "%s", reply->prefix);
    }
    if (em) snprintf(w->err, sizeof(w->err), "%s", em);
    atomic_store_explicit(&w->done, 1, memory_order_release);
}

static void test_shout(EchoCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    ShoutRequest req = {"hello"};
    echo_ctx_shout(ctx, &req, on_shout, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, "c-abi: HELLO") == 0);
    assert(strcmp(w.text_b, "c-abi") == 0);
}

int main(void) {
    EchoCtx* ctx = make_ctx();
    test_shout(ctx);
    echo_ctx_destroy(ctx);
    printf("all abi=c echo e2e checks passed\n");
    return 0;
}
