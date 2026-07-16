#ifndef NIM_FFI_LIB_ECHO_C_ABI_H_INCLUDED
#define NIM_FFI_LIB_ECHO_C_ABI_H_INCLUDED
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define NIMFFI_RET_OK 0
#define NIMFFI_RET_ERR 1
#define NIMFFI_RET_MISSING_CALLBACK 2
/* Non-terminal: the request is still running. Fires every ~5s with `msg`
   carrying the elapsed milliseconds as decimal text; always followed by a
   terminal RET_OK/RET_ERR. Ignore it unless you want progress. */
#define NIMFFI_RET_STALE_WARN 3

/* `abi = c` wire structs — the C ABI. Strings are borrowed, NUL-terminated
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

typedef void (*EchoShoutReplyFn)(int err_code, const ShoutResponse* reply, const char* err_msg, void* user_data);
typedef void (*EchoVersionReplyFn)(int err_code, const char* reply, const char* err_msg, void* user_data);

typedef void (*EchoCreateRawFn)(int err_code, const char* ctx_addr, const char* err_msg, void* user_data);
/* Raw reply of a scalar-fast-path export: `msg`/`len` are bytes (a string
   return's UTF-8, or the 8-byte native-endian scalar image), not
   NUL-terminated and valid only for the duration of the call. */
typedef void (*EchoScalarRawFn)(int caller_ret, char* msg, size_t len, void* user_data);
#ifndef NIMFFI_ABI_DUP_CSTR_N
#define NIMFFI_ABI_DUP_CSTR_N
/* NUL-terminated copy of a length-delimited byte run; NULL if it can't. */
static inline char* nimffi_abi_dup_cstr_n(const char* s, size_t n) {
    if (n == SIZE_MAX) return NULL;
    char* p = (char*)malloc(n + 1);
    if (p) {
        if (n > 0) memcpy(p, s, n);
        p[n] = '\0';
    }
    return p;
}
#endif
#ifdef __cplusplus
extern "C" {
#endif

void* echo_create(const EchoCreateCtorReq* req, EchoCreateRawFn on_created, void* user_data);
int echo_shout(void* ctx, EchoShoutReplyFn on_reply, void* user_data, const EchoShoutReq* req);
int echo_version(void* ctx, EchoScalarRawFn callback, void* user_data);
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
    if (!box) return;
    if (ret == NIMFFI_RET_STALE_WARN) return;
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

typedef struct { EchoVersionReplyFn fn; void* user_data; } EchoVersionScalarBox;
static void echo_version_scalar_reply(int caller_ret, char* msg, size_t len, void* ud) {
    EchoVersionScalarBox* box = (EchoVersionScalarBox*)ud;
    if (!box) return;
    EchoVersionReplyFn fn = box->fn;
    void* user_data = box->user_data;
    free(box);
    if (!fn) return;
    if (caller_ret != NIMFFI_RET_OK) {
        char* em = nimffi_abi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        fn(caller_ret, "", em ? em : "FFI call failed", user_data);
        free(em);
        return;
    }
    char* reply = nimffi_abi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
    if (!reply) {
        fn(NIMFFI_RET_ERR, "", "out of memory", user_data);
        return;
    }
    fn(NIMFFI_RET_OK, reply, "", user_data);
    free(reply);
}

static inline int echo_ctx_version(const EchoCtx* ctx, EchoVersionReplyFn on_reply, void* user_data) {
    EchoVersionScalarBox* box = (EchoVersionScalarBox*)malloc(sizeof(EchoVersionScalarBox));
    if (!box) {
        if (on_reply) on_reply(-1, "", "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    return echo_version(ctx->ptr, echo_version_scalar_reply, box);
}

#endif /* NIM_FFI_LIB_ECHO_C_ABI_H_INCLUDED */
