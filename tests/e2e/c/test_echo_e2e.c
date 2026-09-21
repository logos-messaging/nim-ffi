/* Compiles and runs the second generated C header; the diff check never compiles it. */
#include "echo.h"
#include "waiter.h"

static EchoCtx* make_ctx(void) {
    EchoConfig config = {"X-ECHO"};
    EchoCtx* ctx = NULL;
    char* err = NULL;
    int rc = echo_ctx_create_sync(&config, &ctx, &err, WAIT_LIMIT_MS);
    if (rc != NIMFFI_RET_OK) {
        fprintf(stderr, "create failed (%d): %s\n", rc, err ? err : "?");
    }
    assert(rc == NIMFFI_RET_OK);
    assert(ctx != NULL && err == NULL);
    return ctx;
}

static void test_create_async(void) {
    CreateWaiter w;
    memset(&w, 0, sizeof(w));
    EchoConfig config = {"ASYNC"};
    EchoCtx* ctx = NULL;
    assert(echo_ctx_create(&config, &ctx, on_created, &w) == NIMFFI_RET_OK);
    assert(ctx != NULL && w.done == 0);
    WAIT_DONE(w.done, echo_ctx_pump_once(ctx, 50, NULL));
    assert(w.done == 1 && w.ret == NIMFFI_RET_OK);
    assert(echo_ctx_destroy(ctx) == NIMFFI_RET_OK);
}

static void on_shout(int ret, const ShoutResponse* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->ret = ret;
    if (reply) {
        if (reply->shouted)
            snprintf(w->text_a, sizeof(w->text_a), "%s", reply->shouted);
        if (reply->prefix)
            snprintf(w->text_b, sizeof(w->text_b), "%s", reply->prefix);
    }
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

static void test_shout(EchoCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    ShoutRequest req = {"hello"};
    assert(echo_ctx_shout(ctx, &req, on_shout, &w, NULL) == NIMFFI_RET_OK);
    assert(w.done == 0);
    WAIT_DONE(w.done, echo_ctx_pump_once(ctx, 50, NULL));
    assert(w.done == 1 && w.ret == NIMFFI_RET_OK);
    assert(strcmp(w.text_a, "X-ECHO: HELLO") == 0);
    assert(strcmp(w.text_b, "X-ECHO") == 0);

    ShoutResponse out;
    assert(echo_ctx_shout_sync(ctx, &req, &out, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(strcmp(out.shouted, "X-ECHO: HELLO") == 0);
    echo_free_ShoutResponse(&out);
}

static void test_shout_too_long(EchoCtx* ctx) {
    /* Fixed size: MAX_SHOUT_LEN is a const object, so sizing off it gives a VLA. */
    char text[1024];
    assert(MAX_SHOUT_LEN + 1 < (int64_t)sizeof(text));
    memset(text, 'a', (size_t)MAX_SHOUT_LEN + 1);
    text[MAX_SHOUT_LEN + 1] = '\0';

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    ShoutRequest req = {text};
    assert(echo_ctx_shout(ctx, &req, on_shout, &w, NULL) == NIMFFI_RET_OK);
    WAIT_DONE(w.done, echo_ctx_pump_once(ctx, 50, NULL));
    assert(w.ret == NIMFFI_RET_ERR);
    assert(strstr(w.err, "must not exceed") != NULL);

    ShoutResponse out;
    char* err = NULL;
    assert(echo_ctx_shout_sync(ctx, &req, &out, &err, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_ERR);
    assert(err != NULL && strstr(err, "must not exceed") != NULL);
    free(err);
    assert(out.shouted == NULL);
}

static void test_version(EchoCtx* ctx) {
    const char* version = NULL;
    assert(echo_ctx_version_sync(ctx, &version, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(strcmp(version, "nim-echo v0.1.0") == 0);
    free((void*)version);
}

/* A library without events still has the pump: replies, liveness and `closed` use it. */
static void test_pump_without_events(EchoCtx* ctx) {
    EchoHandlers handlers;
    memset(&handlers, 0, sizeof(handlers));
    assert(echo_ctx_pump_once(ctx, 0, &handlers) == NIMFFI_RET_TIMEOUT);
    assert(echo_ctx_pump_once(ctx, 20, NULL) == NIMFFI_RET_TIMEOUT);
}

/* A host can hand back a nil or stale handle as its very first call, before
   any ctx exists and so before the Nim runtime is up. The refusal's text is a
   Nim allocation, so the guard must initialize the library first. */
static void test_nil_ctx_first_call(void) {
    EchoCtx nil_ctx;
    memset(&nil_ctx, 0, sizeof(nil_ctx));

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    ShoutRequest req = {"hello"};
    assert(echo_ctx_shout(&nil_ctx, &req, on_shout, &w, NULL) == NIMFFI_RET_INVALID_CTX);
    assert(strstr(echo_last_error(), "not a valid FFI context") != NULL);
    /* Refused: nothing was recorded and nothing is called, now or later. */
    assert(w.done == 0 && nil_ctx.pending.len == 0);
    free(nil_ctx.pending.items);
}

/* {.ffiStatic.} procs take no context: they must work before any ctx exists. */
static void test_statics(void) {
    const char* version = NULL;
    assert(echo_static_lib_version_sync(&version, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(strcmp(version, "nim-echo v0.1.0") == 0);
    free((void*)version);

    /* Two in flight on the static context, each with its own callback. */
    ReplyWaiter wv;
    ReplyWaiter ws;
    memset(&wv, 0, sizeof(wv));
    memset(&ws, 0, sizeof(ws));
    ShoutRequest req = {"anon"};
    assert(echo_static_shout_anon(&req, on_shout, &ws, NULL) == NIMFFI_RET_OK);
    assert(echo_static_lib_version(on_str, &wv, NULL) == NIMFFI_RET_OK);
    WAIT_DONE(wv.done && ws.done, echo_static_pump_once(50, NULL));
    assert(wv.done == 1 && wv.ret == NIMFFI_RET_OK);
    assert(strcmp(wv.text_a, "nim-echo v0.1.0") == 0);
    assert(ws.done == 1 && ws.ret == NIMFFI_RET_OK);
    assert(strcmp(ws.text_a, "ANON") == 0);
    assert(ws.text_b[0] == '\0');

    ShoutResponse out;
    assert(echo_static_shout_anon_sync(&req, &out, NULL, WAIT_LIMIT_MS, NULL) == NIMFFI_RET_OK);
    assert(strcmp(out.shouted, "ANON") == 0);
    echo_free_ShoutResponse(&out);
}

int main(void) {
    /* First: it is the only call that can catch an uninitialized runtime. */
    test_nil_ctx_first_call();
    test_statics();
    EchoCtx* ctx = make_ctx();
    test_create_async();
    test_shout(ctx);
    test_shout_too_long(ctx);
    test_version(ctx);
    test_pump_without_events(ctx);
    assert(echo_ctx_destroy(ctx) == NIMFFI_RET_OK);
    assert(echo_shutdown() == NIMFFI_RET_OK);
    printf("all C echo e2e checks passed\n");
    return 0;
}
