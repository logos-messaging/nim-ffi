#ifndef NIM_FFI_LIB_ECHO_H_INCLUDED
#define NIM_FFI_LIB_ECHO_H_INCLUDED
#include "nim_ffi_cbor.h"

/* ============================================================ */
/* Generated constants                                          */
/* ============================================================ */

static const int64_t MAX_SHOUT_LEN = 512;

/* ============================================================ */
/* Generated types (user-declared + per-proc request envelopes) */
/* ============================================================ */

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
    char _nimffi_empty; /* C forbids empty structs */
} EchoVersionReq;
typedef struct {
    char _nimffi_empty; /* C forbids empty structs */
} EchoLibVersionReq;
typedef struct {
    ShoutRequest req;
} EchoShoutAnonReq;

static inline CborError echo_enc_EchoConfig(
        CborEncoder* e, const EchoConfig* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "prefix");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->prefix);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoConfig(
        CborValue* it, EchoConfig* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "prefix", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->prefix);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_EchoConfig(EchoConfig* v) {
    if (!v) return;
    do { free((void*)v->prefix); v->prefix = NULL; } while (0);
}
static inline CborError echo_enc_ShoutRequest(
        CborEncoder* e, const ShoutRequest* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "text");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->text);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_ShoutRequest(
        CborValue* it, ShoutRequest* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "text", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->text);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_ShoutRequest(ShoutRequest* v) {
    if (!v) return;
    do { free((void*)v->text); v->text = NULL; } while (0);
}
static inline CborError echo_enc_ShoutResponse(
        CborEncoder* e, const ShoutResponse* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "shouted");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->shouted);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "prefix");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->prefix);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_ShoutResponse(
        CborValue* it, ShoutResponse* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "shouted", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->shouted);
    if (err) return err;
    err = cbor_value_map_find_value(it, "prefix", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->prefix);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_ShoutResponse(ShoutResponse* v) {
    if (!v) return;
    do { free((void*)v->shouted); v->shouted = NULL; } while (0);
    do { free((void*)v->prefix); v->prefix = NULL; } while (0);
}
static inline CborError echo_enc_EchoCreateCtorReq(
        CborEncoder* e, const EchoCreateCtorReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "config");
    if (err) return err;
    err = echo_enc_EchoConfig(&m, &v->config);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoCreateCtorReq(
        CborValue* it, EchoCreateCtorReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "config", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = echo_dec_EchoConfig(&field, &out->config);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_EchoCreateCtorReq(EchoCreateCtorReq* v) {
    if (!v) return;
    echo_free_EchoConfig(&v->config);
}
static inline CborError echo_enc_EchoShoutReq(
        CborEncoder* e, const EchoShoutReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req");
    if (err) return err;
    err = echo_enc_ShoutRequest(&m, &v->req);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoShoutReq(
        CborValue* it, EchoShoutReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "req", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = echo_dec_ShoutRequest(&field, &out->req);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_EchoShoutReq(EchoShoutReq* v) {
    if (!v) return;
    echo_free_ShoutRequest(&v->req);
}
static inline CborError echo_enc_EchoVersionReq(
        CborEncoder* e, const EchoVersionReq* v) {
    (void)v;
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoVersionReq(
        CborValue* it, EchoVersionReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    (void)out;
    return cbor_value_advance(it);
}
static inline CborError echo_enc_EchoLibVersionReq(
        CborEncoder* e, const EchoLibVersionReq* v) {
    (void)v;
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoLibVersionReq(
        CborValue* it, EchoLibVersionReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    (void)out;
    return cbor_value_advance(it);
}
static inline CborError echo_enc_EchoShoutAnonReq(
        CborEncoder* e, const EchoShoutAnonReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req");
    if (err) return err;
    err = echo_enc_ShoutRequest(&m, &v->req);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoShoutAnonReq(
        CborValue* it, EchoShoutAnonReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "req", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = echo_dec_ShoutRequest(&field, &out->req);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_EchoShoutAnonReq(EchoShoutAnonReq* v) {
    if (!v) return;
    echo_free_ShoutRequest(&v->req);
}

/* ============================================================ */
/* C ABI declarations (symbols exported by the Nim dylib)       */
/* ============================================================ */
#ifdef __cplusplus
extern "C" {
#endif

/** Creates an echo context that prefixes every reply with `config.prefix`. */
void* echo_create(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);
/** Upper-cases `req.text` and returns it behind the context's prefix. */
int echo_shout(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
/** Returns the library's version string. */
int echo_version(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int echo_lib_version(FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int echo_shout_anon(FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
/** Releases the echo context. */
int echo_destroy(void* ctx);
/**
 * Take the next message of `ctx` out of the library: an event, a liveness report
 * or the end of the context. `*msg` is set to a message the library owns, or to NULL.
 * `timeout_ms` 0 never blocks; a negative value waits until a message arrives or
 * the context closes.
 * Returns NIMFFI_RET_OK (`*msg` is set), NIMFFI_RET_TIMEOUT (nothing arrived in
 * time), NIMFFI_RET_CLOSED (the context was destroyed or recycled; `*msg` is a
 * NIMFFI_MSG_CLOSED whose ret_code is NIMFFI_RET_OK, or NIMFFI_RET_ERR with UTF-8
 * text in the payload saying why), NIMFFI_RET_INVALID_CTX (`ctx` is NULL, forged
 * or already destroyed), NIMFFI_RET_BUSY (another thread is inside poll on this
 * context) or NIMFFI_RET_ERR (`msg` is NULL).
 * Lifetime: the message and its payload belong to the library and stay valid until the next
 * poll on the same context, whatever that poll returns. Never free it, and decode
 * it before polling again.
 * Single consumer: one thread at a time polls a context. Any host thread will do;
 * it needs no setup.
 */
int echo_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);
/**
 * A handle to wait on instead of blocking in poll, for a host with an event loop
 * of its own. It is ready while a message waits or the context is closed.
 * Linux: an epoll fd. macOS/BSD: a kqueue fd. Wait until it is readable with
 * poll(2), select(2) or the host's own epoll/kqueue; never read from it.
 * Windows: an Event HANDLE (cast the returned value) that can only be waited on,
 * with WaitForSingleObject or WaitForMultipleObjects.
 * Once it is ready, poll with a timeout of 0 until NIMFFI_RET_TIMEOUT.
 * A stalled FFI thread is only noticed inside poll, so the handle does not become
 * ready for it: a host that wants NIMFFI_MSG_NOT_RESPONDING also polls about once
 * a second.
 * Returns -1 on failure. Each call returns a new handle, which the caller owns
 * and closes with close(), or CloseHandle on Windows.
 */
intptr_t echo_poll_fd(void* ctx);
/**
 * Stop every context the library still holds and join their threads.
 * Call it before the process exits when a context is still alive, or when a
 * static proc built the shared context.
 * Returns 0 when every context stopped, 1 when one was left running.
 */
int echo_shutdown(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

/* CBOR buffer adapters (typed codec → void* driver signature) */
static inline CborError echo_encv_EchoCreateCtorReq(CborEncoder* e, const void* v) { return echo_enc_EchoCreateCtorReq(e, (const EchoCreateCtorReq*)v); }
static inline CborError echo_encv_EchoShoutReq(CborEncoder* e, const void* v) { return echo_enc_EchoShoutReq(e, (const EchoShoutReq*)v); }
static inline CborError echo_encv_EchoVersionReq(CborEncoder* e, const void* v) { return echo_enc_EchoVersionReq(e, (const EchoVersionReq*)v); }
static inline CborError echo_encv_EchoLibVersionReq(CborEncoder* e, const void* v) { return echo_enc_EchoLibVersionReq(e, (const EchoLibVersionReq*)v); }
static inline CborError echo_encv_EchoShoutAnonReq(CborEncoder* e, const void* v) { return echo_enc_EchoShoutAnonReq(e, (const EchoShoutAnonReq*)v); }
static inline CborError echo_decv_ShoutResponse(CborValue* it, void* v) { return echo_dec_ShoutResponse(it, (ShoutResponse*)v); }
static inline CborError echo_decv_Str(CborValue* it, void* v) { return nimffi_dec_str(it, (const char**)v); }

/* ============================================================ */
/* echo API                                                     */
/* ============================================================ */
/* Context: echo_ctx_create(), echo_ctx_destroy().
 *
 * Requests. The reply arrives once, through the callback given to the
 * call, on the library's FFI thread:
 *   echo_ctx_shout()
 *   echo_ctx_version()
 *   echo_static_lib_version()
 *   echo_static_shout_anon()
 *
 * Messages from the library. The binding starts no thread: the host takes
 * them out with echo_ctx_pump_once(), which calls the matching
 * entry of EchoHandlers on the calling thread:
 *   not_responding, responding, closed
 */
typedef struct {
    void* ptr;
} EchoCtx;

typedef void (*EchoCreateFn)(int err_code, EchoCtx* ctx, const char* err_msg, void* user_data);
typedef struct { EchoCreateFn fn; void* user_data; } EchoCreateBox;
static void echo_create_trampoline(int ret, const char* msg, size_t len, void* ud) {
    EchoCreateBox* box = (EchoCreateBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI create failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    const char* addr;
    memset(&addr, 0, sizeof(addr));
    if (nimffi_decode_from_buf(echo_decv_Str, (const uint8_t*)msg, len, &addr, &err) != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        free(box);
        return;
    }
    char* endp = NULL;
    unsigned long long a = addr ? strtoull(addr, &endp, 10) : 0;
    bool ok = addr && addr[0] != '\0' && endp && *endp == '\0';
    free((void*)addr);
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

/** Creates an echo context that prefixes every reply with `config.prefix`. */
static inline int echo_ctx_create(const EchoConfig* config, EchoCreateFn on_created, void* user_data) {
    EchoCreateCtorReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.config = *config;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(echo_encv_EchoCreateCtorReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_created) on_created(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    EchoCreateBox* box = (EchoCreateBox*)malloc(sizeof(EchoCreateBox));
    if (!box) {
        free(req_buf);
        if (on_created) on_created(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_created;
    box->user_data = user_data;
    (void)echo_create(req_buf, req_len, echo_create_trampoline, box);
    free(req_buf);
    return 0;
}

/** Releases the echo context. */
static inline int echo_ctx_destroy(EchoCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    if (ctx->ptr) { rc = echo_destroy(ctx->ptr); ctx->ptr = NULL; }
    free(ctx);
    return rc;
}

/* Everything echo can send. A NULL entry means "ignore". Each
 * handler runs on the thread that pumps; what it is handed belongs to the
 * binding and is valid only until it returns. */
typedef struct {
    /* `reason` is a NIMFFI_NOT_RESPONDING_*: the FFI thread stalled, or the event
     * queue overflowed and requests are refused from now on. */
    void (*not_responding)(uint64_t reason, void* user_data);
    /* The FFI thread's heartbeat resumed. */
    void (*responding)(void* user_data);
    /* The context is gone. `ret` is NIMFFI_RET_OK, or NIMFFI_RET_ERR with `reason`
     * (a NUL-terminated copy, NULL when none) saying why it was quarantined. */
    void (*closed)(int ret, const char* reason, void* user_data);
    void* user_data;
} EchoHandlers;

/* Decodes `msg` fully, then calls its handler, then frees what it decoded.
 * Returns 0, also for an event this header does not know, or -1 on a decode
 * error or an unknown message kind. */
static inline int echo_ctx_dispatch(EchoCtx* ctx, const NimFfiMsg* msg, const EchoHandlers* handlers) {
    (void)ctx;
    if (!msg) return -1;
    switch (msg->kind) {
    case NIMFFI_MSG_EVENT:
        return 0;
    case NIMFFI_MSG_NOT_RESPONDING:
        if (handlers && handlers->not_responding) handlers->not_responding(msg->aux, handlers->user_data);
        return 0;
    case NIMFFI_MSG_RESPONDING:
        if (handlers && handlers->responding) handlers->responding(handlers->user_data);
        return 0;
    case NIMFFI_MSG_CLOSED: {
        if (!handlers || !handlers->closed) return 0;
        char* reason = NULL;
        if (msg->len > 0) reason = nimffi_dup_cstr_n((const char*)msg->payload, msg->len);
        handlers->closed((int)msg->ret_code, reason, handlers->user_data);
        free(reason);
        return 0;
    }
    default:
        return -1;
    }
}

/* One echo_poll() and the dispatch of what it returned.
 * Returns the poll code (NIMFFI_RET_OK, _TIMEOUT, _CLOSED after the `closed`
 * handler ran, _INVALID_CTX, _BUSY, _ERR), or -1 when the message did not
 * dispatch. `ctx` must stay alive for the whole call: stop pumping before
 * echo_ctx_destroy(). */
static inline int echo_ctx_pump_once(EchoCtx* ctx, int32_t timeout_ms, const EchoHandlers* handlers) {
    if (!ctx) return NIMFFI_RET_INVALID_CTX;
    const NimFfiMsg* msg = NULL;
    int rc = echo_poll(ctx->ptr, timeout_ms, &msg);
    if (rc != NIMFFI_RET_OK && rc != NIMFFI_RET_CLOSED) return rc;
    if (echo_ctx_dispatch(ctx, msg, handlers) != 0) return -1;
    return rc;
}

/* See echo_poll_fd(): the caller owns and closes the handle. */
static inline intptr_t echo_ctx_poll_fd(const EchoCtx* ctx) {
    if (!ctx) return -1;
    return echo_poll_fd(ctx->ptr);
}

typedef void (*EchoShoutReplyFn)(int err_code, const ShoutResponse* reply, const char* err_msg, void* user_data);
typedef struct { EchoShoutReplyFn fn; void* user_data; } EchoShoutCallBox;
static void echo_shout_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    EchoShoutCallBox* box = (EchoShoutCallBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI call failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    ShoutResponse out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(echo_decv_ShoutResponse, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        echo_free_ShoutResponse(&out);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    echo_free_ShoutResponse(&out);
    free(box);
}
/** Upper-cases `req.text` and returns it behind the context's prefix. */
static inline int echo_ctx_shout(const EchoCtx* ctx, const ShoutRequest* req, EchoShoutReplyFn on_reply, void* user_data) {
    EchoShoutReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(echo_encv_EchoShoutReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_reply) on_reply(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    EchoShoutCallBox* box = (EchoShoutCallBox*)malloc(sizeof(EchoShoutCallBox));
    if (!box) {
        free(req_buf);
        if (on_reply) on_reply(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    int ret = echo_shout(ctx->ptr, echo_shout_reply_trampoline, box, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        if (on_reply) on_reply(-1, NULL, "RET_MISSING_CALLBACK (internal error)", user_data);
        free(box);
        return -1;
    }
    return 0;
}

typedef void (*EchoVersionReplyFn)(int err_code, const char* const* reply, const char* err_msg, void* user_data);
typedef struct { EchoVersionReplyFn fn; void* user_data; } EchoVersionCallBox;
static void echo_version_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    EchoVersionCallBox* box = (EchoVersionCallBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI call failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    const char* out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(echo_decv_Str, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        do { free((void*)out); out = NULL; } while (0);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    do { free((void*)out); out = NULL; } while (0);
    free(box);
}
/** Returns the library's version string. */
static inline int echo_ctx_version(const EchoCtx* ctx, EchoVersionReplyFn on_reply, void* user_data) {
    EchoVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(echo_encv_EchoVersionReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_reply) on_reply(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    EchoVersionCallBox* box = (EchoVersionCallBox*)malloc(sizeof(EchoVersionCallBox));
    if (!box) {
        free(req_buf);
        if (on_reply) on_reply(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    int ret = echo_version(ctx->ptr, echo_version_reply_trampoline, box, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        if (on_reply) on_reply(-1, NULL, "RET_MISSING_CALLBACK (internal error)", user_data);
        free(box);
        return -1;
    }
    return 0;
}

typedef void (*EchoLibVersionReplyFn)(int err_code, const char* const* reply, const char* err_msg, void* user_data);
typedef struct { EchoLibVersionReplyFn fn; void* user_data; } EchoLibVersionCallBox;
static void echo_lib_version_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    EchoLibVersionCallBox* box = (EchoLibVersionCallBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI call failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    const char* out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(echo_decv_Str, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        do { free((void*)out); out = NULL; } while (0);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    do { free((void*)out); out = NULL; } while (0);
    free(box);
}
static inline int echo_static_lib_version(EchoLibVersionReplyFn on_reply, void* user_data) {
    EchoLibVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(echo_encv_EchoLibVersionReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_reply) on_reply(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    EchoLibVersionCallBox* box = (EchoLibVersionCallBox*)malloc(sizeof(EchoLibVersionCallBox));
    if (!box) {
        free(req_buf);
        if (on_reply) on_reply(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    int ret = echo_lib_version(echo_lib_version_reply_trampoline, box, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        if (on_reply) on_reply(-1, NULL, "RET_MISSING_CALLBACK (internal error)", user_data);
        free(box);
        return -1;
    }
    return 0;
}

typedef void (*EchoShoutAnonReplyFn)(int err_code, const ShoutResponse* reply, const char* err_msg, void* user_data);
typedef struct { EchoShoutAnonReplyFn fn; void* user_data; } EchoShoutAnonCallBox;
static void echo_shout_anon_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    EchoShoutAnonCallBox* box = (EchoShoutAnonCallBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI call failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    ShoutResponse out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(echo_decv_ShoutResponse, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        echo_free_ShoutResponse(&out);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    echo_free_ShoutResponse(&out);
    free(box);
}
static inline int echo_static_shout_anon(const ShoutRequest* req, EchoShoutAnonReplyFn on_reply, void* user_data) {
    EchoShoutAnonReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(echo_encv_EchoShoutAnonReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_reply) on_reply(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    EchoShoutAnonCallBox* box = (EchoShoutAnonCallBox*)malloc(sizeof(EchoShoutAnonCallBox));
    if (!box) {
        free(req_buf);
        if (on_reply) on_reply(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    int ret = echo_shout_anon(echo_shout_anon_reply_trampoline, box, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        if (on_reply) on_reply(-1, NULL, "RET_MISSING_CALLBACK (internal error)", user_data);
        free(box);
        return -1;
    }
    return 0;
}

#endif /* NIM_FFI_LIB_ECHO_H_INCLUDED */
