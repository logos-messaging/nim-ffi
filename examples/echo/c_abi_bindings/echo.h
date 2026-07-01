#ifndef NIM_FFI_LIB_ECHO_C_ABI_H_INCLUDED
#define NIM_FFI_LIB_ECHO_C_ABI_H_INCLUDED
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#ifndef NIMFFI_RET_OK
#define NIMFFI_RET_OK 0
#define NIMFFI_RET_ERR 1
#define NIMFFI_RET_MISSING_CALLBACK 2
#endif

/* Flat wire structs — the C ABI. Strings are borrowed, NUL-terminated
   `const char*` valid only for the duration of the call they cross. */
typedef struct {
    const char* prefix;
} EchoConfig;
typedef struct {
    const char* text;
} ShoutRequest;
typedef struct {
    const char* shouted;
    const char* prefix;
} ShoutResponse;
typedef struct {
    EchoConfig config;
} EchoCreateCtorReq;
typedef struct {
    ShoutRequest req;
} EchoShoutReq;
typedef struct {
    uint8_t _placeholder; /* C forbids empty structs */
} EchoVersionReq;

typedef void (*EchoShoutReplyFn)(int err_code, const ShoutResponse* reply, const char* err_msg, void* user_data);
typedef void (*EchoVersionReplyFn)(int err_code, const char* reply, const char* err_msg, void* user_data);

typedef void (*EchoCreateRawFn)(int err_code, const char* ctx_addr, const char* err_msg, void* user_data);
#ifdef __cplusplus
extern "C" {
#endif

void* echo_create(const EchoCreateCtorReq* req, EchoCreateRawFn on_created, void* user_data);
int echo_shout(void* ctx, EchoShoutReplyFn on_reply, void* user_data, const EchoShoutReq* req);
int echo_version(void* ctx, EchoVersionReplyFn on_reply, void* user_data, const EchoVersionReq* req);
int echo_destroy(void* ctx);

#ifdef __cplusplus
} /* extern "C" */
#endif

/* High-level context wrapper */
typedef struct {
    void* ptr;
} EchoCtx;

typedef void (*EchoCreateFn)(int err_code, EchoCtx* ctx, const char* err_msg, void* user_data);
typedef struct { EchoCreateFn fn; void* user_data; } EchoCreateBox;
static void echo_create_trampoline(int ret, const char* ctx_addr, const char* err_msg, void* ud) {
    EchoCreateBox* box = (EchoCreateBox*)ud;
    if (!box->fn) { free(box); return; }
    if (ret != 0) {
        box->fn(ret, NULL, err_msg ? err_msg : "FFI create failed", box->user_data);
        free(box);
        return;
    }
    char* endp = NULL;
    unsigned long long a = ctx_addr ? strtoull(ctx_addr, &endp, 10) : 0;
    bool ok = ctx_addr && *ctx_addr && endp && *endp == '\0';
    if (!ok) {
        box->fn(-1, NULL, "FFI create returned non-numeric address", box->user_data);
        free(box);
        return;
    }
    EchoCtx* ctx = (EchoCtx*)calloc(1, sizeof(EchoCtx));
    if (!ctx) {
        box->fn(-1, NULL, "out of memory", box->user_data);
        free(box);
        return;
    }
    ctx->ptr = (void*)(uintptr_t)a;
    box->fn(NIMFFI_RET_OK, ctx, NULL, box->user_data);
    free(box);
}

static inline int echo_ctx_create(const EchoConfig* config, EchoCreateFn on_created, void* user_data) {
    EchoCreateCtorReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.config = *config;
    EchoCreateBox* box = (EchoCreateBox*)malloc(sizeof(EchoCreateBox));
    if (!box) {
        if (on_created) on_created(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_created;
    box->user_data = user_data;
    (void)echo_create(&ffi_req, echo_create_trampoline, box);
    return 0;
}

static inline void echo_ctx_destroy(EchoCtx* ctx) {
    if (!ctx) return;
    if (ctx->ptr) { echo_destroy(ctx->ptr); ctx->ptr = NULL; }
    free(ctx);
}

static inline int echo_ctx_shout(const EchoCtx* ctx, const ShoutRequest* req, EchoShoutReplyFn on_reply, void* user_data) {
    EchoShoutReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    return echo_shout(ctx->ptr, on_reply, user_data, &ffi_req);
}

static inline int echo_ctx_version(const EchoCtx* ctx, EchoVersionReplyFn on_reply, void* user_data) {
    EchoVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    return echo_version(ctx->ptr, on_reply, user_data, &ffi_req);
}

#endif /* NIM_FFI_LIB_ECHO_C_ABI_H_INCLUDED */
