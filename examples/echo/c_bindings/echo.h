/* clock_gettime / CLOCK_REALTIME (used by the sync-call helper) live behind
 * POSIX feature-test macros that strict `-std=c11` would otherwise hide. This
 * self-guard only takes effect when this header is included before any libc
 * header (once <features.h> is pulled in, the level is fixed). For include-
 * order independence, define _POSIX_C_SOURCE>=200809L on the command line — the
 * bundled CMakeLists.txt does this on the headers target. */
#if !defined(_POSIX_C_SOURCE) || (_POSIX_C_SOURCE < 200809L)
#  undef _POSIX_C_SOURCE
#  define _POSIX_C_SOURCE 200809L
#endif

#ifndef NIM_FFI_PRELUDE_H_INCLUDED
#define NIM_FFI_PRELUDE_H_INCLUDED
/* Generated C binding for a nim-ffi library. Requests/responses travel as
 * CBOR (encoded with vendored TinyCBOR on this side, matching the Nim-side
 * cbor_serial codec on the wire — both ends speak RFC 8949).
 *
 * Memory ownership contract:
 *   - Request-side strings/sequences are *borrowed*: the binding only reads
 *     them while encoding, so a string literal wrapped with nimffi_str() is
 *     fine and is never freed by the binding.
 *   - Response-side values returned through an out-parameter are *owned* by
 *     the caller. Release them with the generated <lib>_free_<Type>() helper.
 *   - Error strings handed back through a `char** err` out-parameter are
 *     heap-allocated; release them with free().
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
#include <pthread.h>
#include <time.h>
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

#ifndef NIM_FFI_SYNC_CALL_HELPER_H_INCLUDED
#define NIM_FFI_SYNC_CALL_HELPER_H_INCLUDED
/* Blocking request/response helper. The Nim side delivers the result through
 * an FFICallback that may fire from another thread — and, on a timeout, may
 * fire *after* the caller has given up. The call state is therefore reference
 * counted (one ref for the caller, one for the pending callback); whichever
 * side runs last frees it, so a late callback can never write into freed
 * memory. Mirrors the C++ binding's shared_ptr-guarded ffi_call_. */

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);

typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t cv;
    int refs;
    bool done;
    bool ok;
    uint8_t* bytes;
    size_t len;
    char* err; /* heap C string on failure */
} NimFfiCallState;

static inline NimFfiCallState* nimffi_state_new(void) {
    NimFfiCallState* s = (NimFfiCallState*)calloc(1, sizeof(NimFfiCallState));
    if (!s) {
        return NULL;
    }
    pthread_mutex_init(&s->mtx, NULL);
    pthread_cond_init(&s->cv, NULL);
    s->refs = 2;
    return s;
}

static inline void nimffi_state_unref(NimFfiCallState* s) {
    pthread_mutex_lock(&s->mtx);
    int remaining = --s->refs;
    pthread_mutex_unlock(&s->mtx);
    if (remaining != 0) {
        return;
    }
    pthread_mutex_destroy(&s->mtx);
    pthread_cond_destroy(&s->cv);
    free(s->bytes);
    free(s->err);
    free(s);
}

/* The single FFICallback shared by every blocking call. `user_data` is the
 * NimFfiCallState*; this consumes the callback's reference on every path. */
static inline void nimffi_on_result(
        int ret, const char* msg, size_t len, void* user_data) {
    NimFfiCallState* s = (NimFfiCallState*)user_data;
    pthread_mutex_lock(&s->mtx);
    s->ok = (ret == 0);
    if (msg && len > 0) {
        if (s->ok) {
            s->bytes = (uint8_t*)malloc(len);
            if (s->bytes) {
                memcpy(s->bytes, msg, len);
                s->len = len;
            }
        } else {
            s->err = (char*)malloc(len + 1);
            if (s->err) {
                memcpy(s->err, msg, len);
                s->err[len] = '\0';
            }
        }
    }
    s->done = true;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mtx);
    nimffi_state_unref(s);
}

/* RET_MISSING_CALLBACK from the Nim dispatcher: the callback will never fire,
 * so the request path must reclaim the callback's reference itself. */
#define NIMFFI_RET_MISSING_CALLBACK 2

/* Wait up to timeout_ms for nimffi_on_result to fire on `s`, then hand the
 * success payload back through out_bytes / out_len and drop the caller's
 * reference. Returns 0 on success; -1 and *err (heap) on failure/timeout.
 * The matching state was created by nimffi_state_new() (refs == 2): the
 * callback owns the other reference and frees the state if it fires late. */
static inline int nimffi_wait_result(
        NimFfiCallState* s, uint32_t timeout_ms,
        uint8_t** out_bytes, size_t* out_len, char** err) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(timeout_ms / 1000u);
    deadline.tv_nsec += (long)(timeout_ms % 1000u) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }

    int rc = 0;
    pthread_mutex_lock(&s->mtx);
    while (!s->done && rc == 0) {
        rc = pthread_cond_timedwait(&s->cv, &s->mtx, &deadline);
    }
    bool done = s->done;
    bool ok = s->ok;
    uint8_t* bytes = s->bytes;
    size_t blen = s->len;
    char* emsg = s->err;
    if (done && ok) {
        s->bytes = NULL; /* ownership transferred to caller */
        s->len = 0;
    } else if (done) {
        s->err = NULL;
    }
    pthread_mutex_unlock(&s->mtx);

    int status;
    if (!done) {
        if (err) *err = nimffi_dup_cstr("FFI call timed out");
        status = -1;
    } else if (!ok) {
        if (err) *err = emsg ? emsg : nimffi_dup_cstr("FFI call failed");
        status = -1;
    } else {
        *out_bytes = bytes;
        *out_len = blen;
        status = 0;
    }

    nimffi_state_unref(s);
    return status;
}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_SYNC_CALL_HELPER_H_INCLUDED */


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
    uint32_t timeout_ms;
} EchoCtx;

static inline EchoCtx* echo_ctx_create(const EchoConfig* config, uint32_t timeout_ms, char** err) {
    if (err) *err = NULL;
    EchoCreateCtorReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.config = *config;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(echo_encv_EchoCreateCtorReq, &ffi_req, &req_buf, &req_len, err) != 0) return NULL;
    NimFfiCallState* st = nimffi_state_new();
    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr("out of memory"); return NULL; }
    (void)echo_create(req_buf, req_len, nimffi_on_result, st);
    free(req_buf);
    uint8_t* resp = NULL;
    size_t resp_len = 0;
    if (nimffi_wait_result(st, timeout_ms, &resp, &resp_len, err) != 0) return NULL;
    NimFfiStr addr;
    memset(&addr, 0, sizeof(addr));
    if (nimffi_decode_from_buf(echo_decv_Str, resp, resp_len, &addr, err) != 0) { free(resp); return NULL; }
    free(resp);
    char* endp = NULL;
    unsigned long long a = addr.data ? strtoull(addr.data, &endp, 10) : 0;
    bool ok = addr.data && addr.len > 0 && endp && *endp == '\0';
    nimffi_free_str(&addr);
    if (!ok) { if (err) *err = nimffi_dup_cstr("FFI create returned non-numeric address"); return NULL; }
    EchoCtx* ctx = (EchoCtx*)calloc(1, sizeof(EchoCtx));
    if (!ctx) { if (err) *err = nimffi_dup_cstr("out of memory"); return NULL; }
    ctx->ptr = (void*)(uintptr_t)a;
    ctx->timeout_ms = timeout_ms;
    return ctx;
}

static inline void echo_ctx_destroy(EchoCtx* ctx) {
    if (!ctx) return;
    if (ctx->ptr) { echo_destroy(ctx->ptr); ctx->ptr = NULL; }
    free(ctx);
}

static inline int echo_ctx_shout(const EchoCtx* ctx, const ShoutRequest* req, ShoutResponse* out, char** err) {
    if (err) *err = NULL;
    EchoShoutReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(echo_encv_EchoShoutReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    NimFfiCallState* st = nimffi_state_new();
    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr("out of memory"); return -1; }
    int ret = echo_shout(ctx->ptr, nimffi_on_result, st, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        nimffi_state_unref(st);
        nimffi_state_unref(st);
        if (err) *err = nimffi_dup_cstr("RET_MISSING_CALLBACK (internal error)");
        return -1;
    }
    uint8_t* resp = NULL;
    size_t resp_len = 0;
    if (nimffi_wait_result(st, ctx->timeout_ms, &resp, &resp_len, err) != 0) return -1;
    memset(out, 0, sizeof(*out));
    int dec = nimffi_decode_from_buf(echo_decv_ShoutResponse, resp, resp_len, out, err);
    free(resp);
    if (dec != 0) {
        echo_free_ShoutResponse(out);
        memset(out, 0, sizeof(*out));
    }
    return dec;
}

static inline int echo_ctx_version(const EchoCtx* ctx, NimFfiStr* out, char** err) {
    if (err) *err = NULL;
    EchoVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(echo_encv_EchoVersionReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    NimFfiCallState* st = nimffi_state_new();
    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr("out of memory"); return -1; }
    int ret = echo_version(ctx->ptr, nimffi_on_result, st, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        nimffi_state_unref(st);
        nimffi_state_unref(st);
        if (err) *err = nimffi_dup_cstr("RET_MISSING_CALLBACK (internal error)");
        return -1;
    }
    uint8_t* resp = NULL;
    size_t resp_len = 0;
    if (nimffi_wait_result(st, ctx->timeout_ms, &resp, &resp_len, err) != 0) return -1;
    memset(out, 0, sizeof(*out));
    int dec = nimffi_decode_from_buf(echo_decv_Str, resp, resp_len, out, err);
    free(resp);
    if (dec != 0) {
        nimffi_free_str(out);
        memset(out, 0, sizeof(*out));
    }
    return dec;
}

