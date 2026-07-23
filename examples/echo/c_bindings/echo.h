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
    NimFfiStr prefix;
} EchoConfig;
typedef struct {
    NimFfiStr text;
} ShoutRequest;
typedef struct {
    NimFfiStr shouted;
    NimFfiStr prefix;
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
    nimffi_free_str(&v->prefix);
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
    nimffi_free_str(&v->text);
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
    nimffi_free_str(&v->shouted);
    nimffi_free_str(&v->prefix);
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
/** Releases the echo context. */
int echo_destroy(void* ctx);
uint64_t echo_add_event_listener(void* ctx, const char* event_name, FFICallback callback, void* user_data);
int echo_remove_event_listener(void* ctx, uint64_t listener_id);

#ifdef __cplusplus
} /* extern "C" */
#endif

/* CBOR buffer adapters (typed codec → void* driver signature) */
static inline CborError echo_encv_EchoCreateCtorReq(CborEncoder* e, const void* v) { return echo_enc_EchoCreateCtorReq(e, (const EchoCreateCtorReq*)v); }
static inline CborError echo_encv_EchoShoutReq(CborEncoder* e, const void* v) { return echo_enc_EchoShoutReq(e, (const EchoShoutReq*)v); }
static inline CborError echo_encv_EchoVersionReq(CborEncoder* e, const void* v) { return echo_enc_EchoVersionReq(e, (const EchoVersionReq*)v); }
static inline CborError echo_decv_ShoutResponse(CborValue* it, void* v) { return echo_dec_ShoutResponse(it, (ShoutResponse*)v); }
static inline CborError echo_decv_Str(CborValue* it, void* v) { return nimffi_dec_str(it, (NimFfiStr*)v); }

/* ============================================================ */
/* High-level context wrapper                                   */
/* ============================================================ */
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
    NimFfiStr addr;
    memset(&addr, 0, sizeof(addr));
    if (nimffi_decode_from_buf(echo_decv_Str, (const uint8_t*)msg, len, &addr, &err) != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        free(box);
        return;
    }
    char* endp = NULL;
    unsigned long long a = addr.data ? strtoull(addr.data, &endp, 10) : 0;
    bool ok = addr.data && addr.len > 0 && endp && *endp == '\0';
    nimffi_free_str(&addr);
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

typedef void (*EchoVersionReplyFn)(int err_code, const NimFfiStr* reply, const char* err_msg, void* user_data);
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
    NimFfiStr out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(echo_decv_Str, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        nimffi_free_str(&out);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    nimffi_free_str(&out);
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

#endif /* NIM_FFI_LIB_ECHO_H_INCLUDED */
