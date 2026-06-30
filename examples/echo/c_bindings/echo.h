#ifndef NIM_FFI_PRELUDE_H_INCLUDED
#define NIM_FFI_PRELUDE_H_INCLUDED
/* Generated C binding for a nim-ffi library. Requests/responses travel as
 * CBOR (encoded with vendored TinyCBOR on this side, matching the Nim-side
 * cbor_serial codec on the wire — both ends speak RFC 8949).
 *
 * The API is asynchronous: every method/constructor takes a result callback
 * and returns immediately. The callback fires exactly once — synchronously on
 * a submit-time failure, otherwise from the Nim dispatch thread when the reply
 * arrives.
 *
 * Memory ownership contract:
 *   - Request-side strings/sequences are *borrowed*: the binding only reads
 *     them while encoding, so a string literal wrapped with nimffi_str() is
 *     fine and is never freed by the binding.
 *   - Response values and error strings passed into a result callback are
 *     *owned by the binding* and valid only for the duration of that callback;
 *     the binding reclaims them once the callback returns. The caller never
 *     frees them. (The generated <lib>_free_<Type>() helpers are internal — the
 *     trampolines use them to reclaim decoded payloads.)
 *   - A context handle delivered to a constructor callback is the exception:
 *     ownership transfers to the caller, who releases it with
 *     <lib>_ctx_destroy(). It is a lifecycle handle, not returned data.
 *
 * Trust boundary: the decoders assume the CBOR they parse was produced by the
 * paired Nim library. They reject malformed input rather than trusting it, but
 * they are not hardened against a hostile peer feeding crafted payloads through
 * the raw nimffi_decode_from_buf entry point.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <tinycbor/cbor.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Owned, length-delimited UTF-8 text (Nim `string`/`cstring`). On the request
 * side `data` may point at borrowed storage (see nimffi_str); on the response
 * side it is heap-allocated and freed by nimffi_free_str. Always NUL-padded by
 * one byte after decode so `data` is usable as a C string when it has no
 * embedded NULs. */
typedef struct {
    char* data;
    size_t len;
} NimFfiStr;

/* Owned, length-delimited byte buffer (Nim `seq[byte]`). */
typedef struct {
    uint8_t* data;
    size_t len;
} NimFfiBytes;

/* Wrap a borrowed C string for use as a request field. The returned view is
 * not owned by the binding and must outlive the call that encodes it. */
static inline NimFfiStr nimffi_str(const char* s) {
    NimFfiStr v;
    v.data = (char*)s;
    v.len = s ? strlen(s) : 0;
    return v;
}

static inline void nimffi_free_str(NimFfiStr* v) {
    if (!v || !v->data) {
        return;
    }
    free(v->data);
    v->data = NULL;
    v->len = 0;
}

static inline void nimffi_free_bytes(NimFfiBytes* v) {
    if (!v || !v->data) {
        return;
    }
    free(v->data);
    v->data = NULL;
    v->len = 0;
}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_PRELUDE_H_INCLUDED */

#ifndef NIM_FFI_CBOR_HELPERS_H_INCLUDED
#define NIM_FFI_CBOR_HELPERS_H_INCLUDED
/* Leaf CBOR codecs (scalars, text strings, byte strings) plus the buffer
 * drivers. The per-struct / per-container codecs generated below this header
 * call into these by name (C has no overloading, so each leaf gets a distinct
 * nimffi_enc_* / nimffi_dec_* symbol). Guarded so two nim-ffi headers can
 * share a translation unit. */

#ifdef __cplusplus
extern "C" {
#endif

/* Result delivery callback exported by the Nim dylib: `ret` is 0 on success
 * (then `msg`/`len` carry the CBOR response) or non-zero on failure (then
 * `msg`/`len` carry the error text, which is NOT NUL-terminated). */
typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);

/* RET_MISSING_CALLBACK from the Nim dispatcher: the callback will never fire,
 * so the request path must report the failure itself. */
#define NIMFFI_RET_MISSING_CALLBACK 2

/* ── leaf encoders ─────────────────────────────────────────────────────── */
static inline CborError nimffi_enc_bool(CborEncoder* e, const bool* v) {
    return cbor_encode_boolean(e, *v);
}
static inline CborError nimffi_enc_i64(CborEncoder* e, const int64_t* v) {
    return cbor_encode_int(e, *v);
}
static inline CborError nimffi_enc_i32(CborEncoder* e, const int32_t* v) {
    return cbor_encode_int(e, (int64_t)*v);
}
static inline CborError nimffi_enc_i16(CborEncoder* e, const int16_t* v) {
    return cbor_encode_int(e, (int64_t)*v);
}
static inline CborError nimffi_enc_i8(CborEncoder* e, const int8_t* v) {
    return cbor_encode_int(e, (int64_t)*v);
}
static inline CborError nimffi_enc_u64(CborEncoder* e, const uint64_t* v) {
    return cbor_encode_uint(e, *v);
}
static inline CborError nimffi_enc_u32(CborEncoder* e, const uint32_t* v) {
    return cbor_encode_uint(e, (uint64_t)*v);
}
static inline CborError nimffi_enc_u16(CborEncoder* e, const uint16_t* v) {
    return cbor_encode_uint(e, (uint64_t)*v);
}
static inline CborError nimffi_enc_u8(CborEncoder* e, const uint8_t* v) {
    return cbor_encode_uint(e, (uint64_t)*v);
}
static inline CborError nimffi_enc_f64(CborEncoder* e, const double* v) {
    return cbor_encode_double(e, *v);
}
static inline CborError nimffi_enc_f32(CborEncoder* e, const float* v) {
    return cbor_encode_float(e, *v);
}
static inline CborError nimffi_enc_str(CborEncoder* e, const NimFfiStr* v) {
    return cbor_encode_text_string(e, v->data ? v->data : "", v->len);
}
static inline CborError nimffi_enc_bytes(CborEncoder* e, const NimFfiBytes* v) {
    return cbor_encode_byte_string(e, v->data, v->len);
}

/* ── leaf decoders ─────────────────────────────────────────────────────── */
/* After reading a leaf, the parser must advance past it; both steps
 * short-circuit on the same CborError, so they travel together. */
static inline CborError nimffi_advance_if_ok(CborValue* it, CborError err) {
    if (err) {
        return err;
    }
    return cbor_value_advance(it);
}

static inline CborError nimffi_dec_bool(CborValue* it, bool* out) {
    if (!cbor_value_is_boolean(it)) {
        return CborErrorImproperValue;
    }
    return nimffi_advance_if_ok(it, cbor_value_get_boolean(it, out));
}
static inline CborError nimffi_dec_i64(CborValue* it, int64_t* out) {
    if (!cbor_value_is_integer(it)) {
        return CborErrorImproperValue;
    }
    return nimffi_advance_if_ok(it, cbor_value_get_int64_checked(it, out));
}
static inline CborError nimffi_dec_i32(CborValue* it, int32_t* out) {
    int64_t tmp = 0;
    CborError err = nimffi_dec_i64(it, &tmp);
    if (err) {
        return err;
    }
    *out = (int32_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_i16(CborValue* it, int16_t* out) {
    int64_t tmp = 0;
    CborError err = nimffi_dec_i64(it, &tmp);
    if (err) {
        return err;
    }
    *out = (int16_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_i8(CborValue* it, int8_t* out) {
    int64_t tmp = 0;
    CborError err = nimffi_dec_i64(it, &tmp);
    if (err) {
        return err;
    }
    *out = (int8_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_u64(CborValue* it, uint64_t* out) {
    if (!cbor_value_is_unsigned_integer(it)) {
        return CborErrorImproperValue;
    }
    return nimffi_advance_if_ok(it, cbor_value_get_uint64(it, out));
}
static inline CborError nimffi_dec_u32(CborValue* it, uint32_t* out) {
    uint64_t tmp = 0;
    CborError err = nimffi_dec_u64(it, &tmp);
    if (err) {
        return err;
    }
    *out = (uint32_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_u16(CborValue* it, uint16_t* out) {
    uint64_t tmp = 0;
    CborError err = nimffi_dec_u64(it, &tmp);
    if (err) {
        return err;
    }
    *out = (uint16_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_u8(CborValue* it, uint8_t* out) {
    uint64_t tmp = 0;
    CborError err = nimffi_dec_u64(it, &tmp);
    if (err) {
        return err;
    }
    *out = (uint8_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_f64(CborValue* it, double* out) {
    if (cbor_value_is_double(it)) {
        return nimffi_advance_if_ok(it, cbor_value_get_double(it, out));
    }
    if (cbor_value_is_float(it)) {
        float f = 0.0f;
        CborError err = cbor_value_get_float(it, &f);
        if (err) {
            return err;
        }
        *out = (double)f;
        return cbor_value_advance(it);
    }
    return CborErrorImproperValue;
}
static inline CborError nimffi_dec_f32(CborValue* it, float* out) {
    if (cbor_value_is_float(it)) {
        return nimffi_advance_if_ok(it, cbor_value_get_float(it, out));
    }
    if (cbor_value_is_double(it)) {
        double d = 0.0;
        CborError err = cbor_value_get_double(it, &d);
        if (err) {
            return err;
        }
        *out = (float)d;
        return cbor_value_advance(it);
    }
    return CborErrorImproperValue;
}
static inline CborError nimffi_dec_str(CborValue* it, NimFfiStr* out) {
    if (!cbor_value_is_text_string(it)) {
        return CborErrorImproperValue;
    }
    size_t len = 0;
    CborError err = cbor_value_get_string_length(it, &len);
    if (err) {
        return err;
    }
    if (len == SIZE_MAX) { /* len + 1 would wrap to a 0-byte allocation */
        return CborErrorDataTooLarge;
    }
    /* one extra byte so a NUL-free payload is a valid C string */
    out->data = (char*)malloc(len + 1);
    if (!out->data) {
        return CborErrorOutOfMemory;
    }
    out->len = len;
    size_t copied = len;
    err = cbor_value_copy_text_string(it, out->data, &copied, NULL);
    if (err) {
        free(out->data);
        out->data = NULL;
        out->len = 0;
        return err;
    }
    out->data[len] = '\0';
    return cbor_value_advance(it);
}
static inline CborError nimffi_dec_bytes(CborValue* it, NimFfiBytes* out) {
    if (!cbor_value_is_byte_string(it)) {
        return CborErrorImproperValue;
    }
    size_t len = 0;
    CborError err = cbor_value_get_string_length(it, &len);
    if (err) {
        return err;
    }
    out->data = (uint8_t*)malloc(len ? len : 1);
    if (!out->data) {
        return CborErrorOutOfMemory;
    }
    out->len = len;
    size_t copied = len;
    err = cbor_value_copy_byte_string(it, out->data, &copied, NULL);
    if (err) {
        free(out->data);
        out->data = NULL;
        out->len = 0;
        return err;
    }
    return cbor_value_advance(it);
}

/* ── buffer drivers ────────────────────────────────────────────────────── */
typedef CborError (*nimffi_enc_fn)(CborEncoder*, const void*);
typedef CborError (*nimffi_dec_fn)(CborValue*, void*);

static inline char* nimffi_dup_cstr(const char* s) {
    size_t n = strlen(s) + 1;
    char* p = (char*)malloc(n);
    if (p) {
        memcpy(p, s, n);
    }
    return p;
}

/* NUL-terminated copy of a length-delimited (not NUL-terminated) byte run,
 * for turning the FFICallback's raw error `msg`/`len` into a C string. */
static inline char* nimffi_dup_cstr_n(const char* s, size_t n) {
    char* p = (char*)malloc(n + 1);
    if (p) {
        if (n > 0) {
            memcpy(p, s, n);
        }
        p[n] = '\0';
    }
    return p;
}

/* Encode `val` with `fn` into a freshly malloc'd buffer, doubling on overflow.
 * Returns 0 and sets out/outlen on success; -1 and *err (heap) on failure. */
static inline int nimffi_encode_to_buf(
        nimffi_enc_fn fn, const void* val,
        uint8_t** out, size_t* outlen, char** err) {
    size_t cap = 4096;
    uint8_t* buf = (uint8_t*)malloc(cap);
    if (!buf) {
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    for (;;) {
        CborEncoder enc;
        cbor_encoder_init(&enc, buf, cap, 0);
        CborError e = fn(&enc, val);
        if (e == CborNoError) {
            *outlen = cbor_encoder_get_buffer_size(&enc, buf);
            *out = buf;
            return 0;
        }
        if (e == CborErrorOutOfMemory) {
            size_t extra = cbor_encoder_get_extra_bytes_needed(&enc);
            cap += extra > 0 ? extra : cap;
            uint8_t* grown = (uint8_t*)realloc(buf, cap);
            if (!grown) {
                free(buf);
                if (err) *err = nimffi_dup_cstr("out of memory");
                return -1;
            }
            buf = grown;
            continue;
        }
        free(buf);
        if (err) *err = nimffi_dup_cstr(cbor_error_string(e));
        return -1;
    }
}

/* Decode a CBOR buffer into `out` with `fn`. Returns 0 on success; -1 and
 * *err (heap) on failure. */
static inline int nimffi_decode_from_buf(
        nimffi_dec_fn fn, const uint8_t* buf, size_t len,
        void* out, char** err) {
    CborParser parser;
    CborValue it;
    CborError e = cbor_parser_init(buf, len, 0, &parser, &it);
    if (e != CborNoError) {
        if (err) *err = nimffi_dup_cstr(cbor_error_string(e));
        return -1;
    }
    e = fn(&it, out);
    if (e != CborNoError) {
        if (err) *err = nimffi_dup_cstr(cbor_error_string(e));
        return -1;
    }
    return 0;
}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_CBOR_HELPERS_H_INCLUDED */

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

void* echo_create(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);
int echo_shout(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int echo_version(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
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
    box->fn(0, ctx, NULL, box->user_data);
    free(box);
}

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

static inline void echo_ctx_destroy(EchoCtx* ctx) {
    if (!ctx) return;
    if (ctx->ptr) { echo_destroy(ctx->ptr); ctx->ptr = NULL; }
    free(ctx);
}

typedef void (*EchoShoutReplyFn)(int err_code, const ShoutResponse* reply, const char* err_msg, void* user_data);
typedef struct { EchoShoutReplyFn fn; void* user_data; } EchoShoutCallBox;
static void echo_shout_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    EchoShoutCallBox* box = (EchoShoutCallBox*)ud;
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
    box->fn(0, &out, NULL, box->user_data);
    echo_free_ShoutResponse(&out);
    free(box);
}
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
    box->fn(0, &out, NULL, box->user_data);
    nimffi_free_str(&out);
    free(box);
}
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

