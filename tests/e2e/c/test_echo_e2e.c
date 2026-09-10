/* Compiles and runs the second generated C header; the diff check never compiles it. */
#include "echo.h"
#include "waiter.h"

/* Per library: the ctor callback's context parameter is a distinct type. */
static void on_created(int err_code, EchoCtx* ctx, const char* err_msg, void* user_data) {
    CreateWaiter* w = (CreateWaiter*)user_data;
    w->err_code = err_code;
    w->ctx = ctx;
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

static EchoCtx* make_ctx(void) {
    CreateWaiter w;
    memset(&w, 0, sizeof(w));
    EchoConfig config = {nimffi_str("X-ECHO")};
    echo_ctx_create(&config, on_created, &w);
    wait_done(&w.done);
    if (w.err_code != 0) {
        fprintf(stderr, "create failed: %s\n", w.err[0] ? w.err : "?");
    }
    assert(w.err_code == 0);
    assert(w.ctx != NULL);
    return (EchoCtx*)w.ctx;
}

static void on_shout(int err_code, const ShoutResponse* reply, const char* err_msg, void* user_data) {
    ReplyWaiter* w = (ReplyWaiter*)user_data;
    w->err_code = err_code;
    if (reply) {
        if (reply->shouted.data)
            snprintf(w->text_a, sizeof(w->text_a), "%s", reply->shouted.data);
        if (reply->prefix.data)
            snprintf(w->text_b, sizeof(w->text_b), "%s", reply->prefix.data);
    }
    waiter_settle(&w->done, w->err, sizeof(w->err), err_msg);
}

static void test_shout(EchoCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    ShoutRequest req = {nimffi_str("hello")};
    echo_ctx_shout(ctx, &req, on_shout, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, "X-ECHO: HELLO") == 0);
    assert(strcmp(w.text_b, "X-ECHO") == 0);
}

static void test_shout_too_long(EchoCtx* ctx) {
    /* Fixed size: MAX_SHOUT_LEN is a const object, so sizing off it gives a VLA. */
    char text[1024];
    assert(MAX_SHOUT_LEN + 1 < (int64_t)sizeof(text));
    memset(text, 'a', (size_t)MAX_SHOUT_LEN + 1);
    text[MAX_SHOUT_LEN + 1] = '\0';

    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    ShoutRequest req = {nimffi_str(text)};
    echo_ctx_shout(ctx, &req, on_shout, &w);
    wait_done(&w.done);
    assert(w.err_code != 0);
    assert(strstr(w.err, "must not exceed") != NULL);
}

static void test_version(EchoCtx* ctx) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    echo_ctx_version(ctx, on_str, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, "nim-echo v0.1.0") == 0);
}

/* {.ffiStatic.} procs take no context: they must work before any ctx exists. */
static void test_statics(void) {
    ReplyWaiter w;
    memset(&w, 0, sizeof(w));
    echo_static_lib_version(on_str, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, "nim-echo v0.1.0") == 0);

    memset(&w, 0, sizeof(w));
    ShoutRequest req = {nimffi_str("anon")};
    echo_static_shout_anon(&req, on_shout, &w);
    wait_done(&w.done);
    assert(w.err_code == 0);
    assert(strcmp(w.text_a, "ANON") == 0);
    assert(w.text_b[0] == '\0');
}

int main(void) {
    test_statics();
    EchoCtx* ctx = make_ctx();
    test_shout(ctx);
    test_shout_too_long(ctx);
    test_version(ctx);
    assert(echo_ctx_destroy(ctx) == NIMFFI_RET_OK);
    printf("all C echo e2e checks passed\n");
    return 0;
}
