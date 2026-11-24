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
#ifndef NIM_FFI_BUILTIN_NOT_RESPONDING_REASON_DEFINED
#define NIM_FFI_BUILTIN_NOT_RESPONDING_REASON_DEFINED
typedef enum {
    NOT_RESPONDING_REASON_HEARTBEAT = 0,
    NOT_RESPONDING_REASON_QUEUE_FULL = 1
} NotRespondingReason;
#endif
#ifndef NIM_FFI_BUILTIN_NOT_RESPONDING_EVENT_DEFINED
#define NIM_FFI_BUILTIN_NOT_RESPONDING_EVENT_DEFINED
typedef struct {
    NotRespondingReason reason;
} NotRespondingEvent;
#endif
#ifndef NIM_FFI_BUILTIN_RESPONDING_EVENT_DEFINED
#define NIM_FFI_BUILTIN_RESPONDING_EVENT_DEFINED
typedef struct {
    NotRespondingReason reason;
} RespondingEvent;
#endif
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
static inline CborError echo_enc_NotRespondingReason(
        CborEncoder* e, const NotRespondingReason* v) {
    switch (*v) {
    case NOT_RESPONDING_REASON_HEARTBEAT: return cbor_encode_text_stringz(e, "heartbeat");
    case NOT_RESPONDING_REASON_QUEUE_FULL: return cbor_encode_text_stringz(e, "queueFull");
    }
    return CborErrorImproperValue;
}
static inline CborError echo_dec_NotRespondingReason(
        CborValue* it, NotRespondingReason* out) {
    if (!cbor_value_is_text_string(it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_string_length(it, &len);
    if (err) return err;
    char buf[10];
    if (len >= sizeof(buf)) return CborErrorImproperValue;
    size_t copied = sizeof(buf);
    err = cbor_value_copy_text_string(it, buf, &copied, NULL);
    if (err) return err;
    buf[len] = '\0';
    if (strcmp(buf, "heartbeat") == 0) { *out = NOT_RESPONDING_REASON_HEARTBEAT; return cbor_value_advance(it); }
    if (strcmp(buf, "queueFull") == 0) { *out = NOT_RESPONDING_REASON_QUEUE_FULL; return cbor_value_advance(it); }
    return CborErrorImproperValue;
}
static inline CborError echo_enc_NotRespondingEvent(
        CborEncoder* e, const NotRespondingEvent* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "reason");
    if (err) return err;
    err = echo_enc_NotRespondingReason(&m, &v->reason);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_NotRespondingEvent(
        CborValue* it, NotRespondingEvent* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "reason", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = echo_dec_NotRespondingReason(&field, &out->reason);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline CborError echo_enc_RespondingEvent(
        CborEncoder* e, const RespondingEvent* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "reason");
    if (err) return err;
    err = echo_enc_NotRespondingReason(&m, &v->reason);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_RespondingEvent(
        CborValue* it, RespondingEvent* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "reason", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = echo_dec_NotRespondingReason(&field, &out->reason);
    if (err) return err;
    return cbor_value_advance(it);
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
uint64_t echo_add_event_listener(void* ctx, const char* event_name, FFICallback callback, void* user_data);
/**
 * Unregister a listener by id.
 * A call from another thread returns after the last delivery to that listener,
 * so its user data is then safe to free.
 * A call from inside a listener callback returns at once, and the dispatch in
 * flight then skips the listener that you removed.
 */
int echo_remove_event_listener(void* ctx, uint64_t listener_id);
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

/* Event listener machinery */
typedef void (*EchoNotRespondingFn)(const NotRespondingEvent* evt, void* user_data);
typedef struct { EchoNotRespondingFn fn; void* user_data; } EchoNotRespondingBox;
static void echo_not_responding_trampoline(int ret, const char* msg, size_t len, void* ud) {
    if (!ud || ret != 0 || !msg || len == 0) return;
    EchoNotRespondingBox* box = (EchoNotRespondingBox*)ud;
    if (!box->fn) return;
    CborParser parser;
    CborValue it;
    if (cbor_parser_init((const uint8_t*)msg, len, 0, &parser, &it) != CborNoError) return;
    if (!cbor_value_is_map(&it)) return;
    CborValue payloadField;
    if (cbor_value_map_find_value(&it, "payload", &payloadField) != CborNoError) return;
    NotRespondingEvent payload;
    memset(&payload, 0, sizeof(payload));
    if (echo_dec_NotRespondingEvent(&payloadField, &payload) != CborNoError) return;
    box->fn(&payload, box->user_data);
}

typedef void (*EchoRespondingFn)(const RespondingEvent* evt, void* user_data);
typedef struct { EchoRespondingFn fn; void* user_data; } EchoRespondingBox;
static void echo_responding_trampoline(int ret, const char* msg, size_t len, void* ud) {
    if (!ud || ret != 0 || !msg || len == 0) return;
    EchoRespondingBox* box = (EchoRespondingBox*)ud;
    if (!box->fn) return;
    CborParser parser;
    CborValue it;
    if (cbor_parser_init((const uint8_t*)msg, len, 0, &parser, &it) != CborNoError) return;
    if (!cbor_value_is_map(&it)) return;
    CborValue payloadField;
    if (cbor_value_map_find_value(&it, "payload", &payloadField) != CborNoError) return;
    RespondingEvent payload;
    memset(&payload, 0, sizeof(payload));
    if (echo_dec_RespondingEvent(&payloadField, &payload) != CborNoError) return;
    box->fn(&payload, box->user_data);
}

/* ============================================================ */
/* High-level context wrapper                                   */
/* ============================================================ */
typedef struct {
    uint64_t id;
    void* box;
} EchoCtxListener;

typedef struct {
    void* ptr;
    EchoCtxListener* listeners;
    size_t listeners_len;
    size_t listeners_cap;
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
    void* tok = echo_create(req_buf, req_len, echo_create_trampoline, box);
    free(req_buf);
    return tok ? 0 : -1;
}

/** Releases the echo context. */
static inline int echo_ctx_destroy(EchoCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    if (ctx->ptr) { rc = echo_destroy(ctx->ptr); ctx->ptr = NULL; }
    if (rc == NIMFFI_RET_OK) {
        for (size_t i = 0; i < ctx->listeners_len; i++) free(ctx->listeners[i].box);
    }
    free(ctx->listeners);
    free(ctx);
    return rc;
}

/** The library stopped responding: its FFI thread stalled or the event queue overflowed. */
static inline uint64_t echo_ctx_add_not_responding_listener(EchoCtx* ctx, EchoNotRespondingFn fn, void* user_data) {
    EchoNotRespondingBox* box = (EchoNotRespondingBox*)malloc(sizeof(EchoNotRespondingBox));
    if (!box) return 0;
    box->fn = fn;
    box->user_data = user_data;
    uint64_t id = echo_add_event_listener(ctx->ptr, "not_responding", echo_not_responding_trampoline, box);
    if (id == 0) { free(box); return 0; }
    if (ctx->listeners_len == ctx->listeners_cap) {
        size_t ncap = ctx->listeners_cap ? ctx->listeners_cap * 2 : 4;
        EchoCtxListener* grown = (EchoCtxListener*)realloc(ctx->listeners, ncap * sizeof(EchoCtxListener));
        if (!grown) { echo_remove_event_listener(ctx->ptr, id); free(box); return 0; }
        ctx->listeners = grown;
        ctx->listeners_cap = ncap;
    }
    ctx->listeners[ctx->listeners_len].id = id;
    ctx->listeners[ctx->listeners_len].box = box;
    ctx->listeners_len++;
    return id;
}

/** The library responds again after `not_responding`. */
static inline uint64_t echo_ctx_add_responding_listener(EchoCtx* ctx, EchoRespondingFn fn, void* user_data) {
    EchoRespondingBox* box = (EchoRespondingBox*)malloc(sizeof(EchoRespondingBox));
    if (!box) return 0;
    box->fn = fn;
    box->user_data = user_data;
    uint64_t id = echo_add_event_listener(ctx->ptr, "responding", echo_responding_trampoline, box);
    if (id == 0) { free(box); return 0; }
    if (ctx->listeners_len == ctx->listeners_cap) {
        size_t ncap = ctx->listeners_cap ? ctx->listeners_cap * 2 : 4;
        EchoCtxListener* grown = (EchoCtxListener*)realloc(ctx->listeners, ncap * sizeof(EchoCtxListener));
        if (!grown) { echo_remove_event_listener(ctx->ptr, id); free(box); return 0; }
        ctx->listeners = grown;
        ctx->listeners_cap = ncap;
    }
    ctx->listeners[ctx->listeners_len].id = id;
    ctx->listeners[ctx->listeners_len].box = box;
    ctx->listeners_len++;
    return id;
}

/** Unregister a listener and release the box that holds the handler. */
static inline bool echo_ctx_remove_event_listener(EchoCtx* ctx, uint64_t id) {
    if (id == 0) return false;
    int rc = echo_remove_event_listener(ctx->ptr, id);
    for (size_t i = 0; i < ctx->listeners_len; i++) {
        if (ctx->listeners[i].id == id) {
            free(ctx->listeners[i].box);
            ctx->listeners[i] = ctx->listeners[ctx->listeners_len - 1];
            ctx->listeners_len--;
            break;
        }
    }
    return rc == 0;
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
    return ret;
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
    return ret;
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
    return ret;
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
    return ret;
}

#endif /* NIM_FFI_LIB_ECHO_H_INCLUDED */
