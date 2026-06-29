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
    NimFfiStr name;
} TimerConfig;
typedef struct {
    NimFfiStr message;
    int64_t delayMs;
} EchoRequest;
typedef struct {
    NimFfiStr echoed;
    NimFfiStr timerName;
} EchoResponse;
typedef struct {
    EchoRequest* data;
    size_t len;
} MyTimerSeq_EchoRequest;
typedef struct {
    NimFfiStr* data;
    size_t len;
} MyTimerSeq_Str;
typedef struct {
    bool has_value;
    NimFfiStr value;
} MyTimerOpt_Str;
typedef struct {
    bool has_value;
    int64_t value;
} MyTimerOpt_I64;
typedef struct {
    MyTimerSeq_EchoRequest messages;
    MyTimerSeq_Str tags;
    MyTimerOpt_Str note;
    MyTimerOpt_I64 retries;
} ComplexRequest;
typedef struct {
    NimFfiStr summary;
    int64_t itemCount;
    bool hasNote;
} ComplexResponse;
typedef struct {
    NimFfiStr message;
    int64_t echoCount;
} EchoEvent;
typedef struct {
    NimFfiStr name;
    MyTimerSeq_Str payload;
    int64_t priority;
} JobSpec;
typedef struct {
    int64_t maxAttempts;
    int64_t backoffMs;
    MyTimerSeq_Str retryOn;
} RetryPolicy;
typedef struct {
    int64_t startAtMs;
    int64_t intervalMs;
    MyTimerOpt_I64 jitter;
} ScheduleConfig;
typedef struct {
    NimFfiStr jobId;
    int64_t willRunCount;
    int64_t firstRunAtMs;
    int64_t effectiveBackoffMs;
} ScheduleResult;
typedef struct {
    TimerConfig config;
} MyTimerCreateCtorReq;
typedef struct {
    EchoRequest req;
} MyTimerEchoReq;
typedef struct {
    char _nimffi_empty; /* C forbids empty structs */
} MyTimerVersionReq;
typedef struct {
    ComplexRequest req;
} MyTimerComplexReq;
typedef struct {
    JobSpec job;
    RetryPolicy retry;
    ScheduleConfig schedule;
} MyTimerScheduleReq;

static inline CborError my_timer_enc_TimerConfig(
        CborEncoder* e, const TimerConfig* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "name");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->name);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_TimerConfig(
        CborValue* it, TimerConfig* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "name", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->name);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_TimerConfig(TimerConfig* v) {
    if (!v) return;
    nimffi_free_str(&v->name);
}
static inline CborError my_timer_enc_EchoRequest(
        CborEncoder* e, const EchoRequest* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "message");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->message);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "delayMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->delayMs);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_EchoRequest(
        CborValue* it, EchoRequest* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "message", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->message);
    if (err) return err;
    err = cbor_value_map_find_value(it, "delayMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->delayMs);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_EchoRequest(EchoRequest* v) {
    if (!v) return;
    nimffi_free_str(&v->message);
}
static inline CborError my_timer_enc_EchoResponse(
        CborEncoder* e, const EchoResponse* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "echoed");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->echoed);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "timerName");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->timerName);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_EchoResponse(
        CborValue* it, EchoResponse* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "echoed", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->echoed);
    if (err) return err;
    err = cbor_value_map_find_value(it, "timerName", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->timerName);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_EchoResponse(EchoResponse* v) {
    if (!v) return;
    nimffi_free_str(&v->echoed);
    nimffi_free_str(&v->timerName);
}
static inline CborError my_timer_enc_MyTimerSeq_EchoRequest(
        CborEncoder* e, const MyTimerSeq_EchoRequest* v) {
    CborEncoder arr;
    CborError err = cbor_encoder_create_array(e, &arr, v->len);
    if (err) return err;
    for (size_t i = 0; i < v->len; i++) {
        err = my_timer_enc_EchoRequest(&arr, &v->data[i]);
        if (err) return err;
    }
    return cbor_encoder_close_container(e, &arr);
}
static inline CborError my_timer_dec_MyTimerSeq_EchoRequest(
        CborValue* it, MyTimerSeq_EchoRequest* out) {
    if (!cbor_value_is_array(it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_array_length(it, &len);
    if (err) return err;
    out->data = (EchoRequest*)calloc(len ? len : 1, sizeof(EchoRequest));
    if (!out->data) return CborErrorOutOfMemory;
    out->len = len;
    CborValue inner;
    err = cbor_value_enter_container(it, &inner);
    if (err) return err;
    for (size_t i = 0; i < len; i++) {
        err = my_timer_dec_EchoRequest(&inner, &out->data[i]);
        if (err) return err;
    }
    return cbor_value_leave_container(it, &inner);
}
static inline void my_timer_free_MyTimerSeq_EchoRequest(MyTimerSeq_EchoRequest* v) {
    if (!v || !v->data) return;
    for (size_t i = 0; i < v->len; i++) my_timer_free_EchoRequest(&v->data[i]);
    free(v->data);
    v->data = NULL;
    v->len = 0;
}
static inline CborError my_timer_enc_MyTimerSeq_Str(
        CborEncoder* e, const MyTimerSeq_Str* v) {
    CborEncoder arr;
    CborError err = cbor_encoder_create_array(e, &arr, v->len);
    if (err) return err;
    for (size_t i = 0; i < v->len; i++) {
        err = nimffi_enc_str(&arr, &v->data[i]);
        if (err) return err;
    }
    return cbor_encoder_close_container(e, &arr);
}
static inline CborError my_timer_dec_MyTimerSeq_Str(
        CborValue* it, MyTimerSeq_Str* out) {
    if (!cbor_value_is_array(it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_array_length(it, &len);
    if (err) return err;
    out->data = (NimFfiStr*)calloc(len ? len : 1, sizeof(NimFfiStr));
    if (!out->data) return CborErrorOutOfMemory;
    out->len = len;
    CborValue inner;
    err = cbor_value_enter_container(it, &inner);
    if (err) return err;
    for (size_t i = 0; i < len; i++) {
        err = nimffi_dec_str(&inner, &out->data[i]);
        if (err) return err;
    }
    return cbor_value_leave_container(it, &inner);
}
static inline void my_timer_free_MyTimerSeq_Str(MyTimerSeq_Str* v) {
    if (!v || !v->data) return;
    for (size_t i = 0; i < v->len; i++) nimffi_free_str(&v->data[i]);
    free(v->data);
    v->data = NULL;
    v->len = 0;
}
static inline CborError my_timer_enc_MyTimerOpt_Str(
        CborEncoder* e, const MyTimerOpt_Str* v) {
    if (!v->has_value) return cbor_encode_null(e);
    return nimffi_enc_str(e, &v->value);
}
static inline CborError my_timer_dec_MyTimerOpt_Str(
        CborValue* it, MyTimerOpt_Str* out) {
    if (cbor_value_is_null(it)) {
        out->has_value = false;
        memset(&out->value, 0, sizeof(out->value));
        return cbor_value_advance(it);
    }
    out->has_value = true;
    return nimffi_dec_str(it, &out->value);
}
static inline void my_timer_free_MyTimerOpt_Str(MyTimerOpt_Str* v) {
    if (!v || !v->has_value) return;
    nimffi_free_str(&v->value);
    v->has_value = false;
}
static inline CborError my_timer_enc_MyTimerOpt_I64(
        CborEncoder* e, const MyTimerOpt_I64* v) {
    if (!v->has_value) return cbor_encode_null(e);
    return nimffi_enc_i64(e, &v->value);
}
static inline CborError my_timer_dec_MyTimerOpt_I64(
        CborValue* it, MyTimerOpt_I64* out) {
    if (cbor_value_is_null(it)) {
        out->has_value = false;
        memset(&out->value, 0, sizeof(out->value));
        return cbor_value_advance(it);
    }
    out->has_value = true;
    return nimffi_dec_i64(it, &out->value);
}
static inline CborError my_timer_enc_ComplexRequest(
        CborEncoder* e, const ComplexRequest* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 4);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "messages");
    if (err) return err;
    err = my_timer_enc_MyTimerSeq_EchoRequest(&m, &v->messages);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "tags");
    if (err) return err;
    err = my_timer_enc_MyTimerSeq_Str(&m, &v->tags);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "note");
    if (err) return err;
    err = my_timer_enc_MyTimerOpt_Str(&m, &v->note);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "retries");
    if (err) return err;
    err = my_timer_enc_MyTimerOpt_I64(&m, &v->retries);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_ComplexRequest(
        CborValue* it, ComplexRequest* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "messages", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerSeq_EchoRequest(&field, &out->messages);
    if (err) return err;
    err = cbor_value_map_find_value(it, "tags", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerSeq_Str(&field, &out->tags);
    if (err) return err;
    err = cbor_value_map_find_value(it, "note", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerOpt_Str(&field, &out->note);
    if (err) return err;
    err = cbor_value_map_find_value(it, "retries", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerOpt_I64(&field, &out->retries);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_ComplexRequest(ComplexRequest* v) {
    if (!v) return;
    my_timer_free_MyTimerSeq_EchoRequest(&v->messages);
    my_timer_free_MyTimerSeq_Str(&v->tags);
    my_timer_free_MyTimerOpt_Str(&v->note);
}
static inline CborError my_timer_enc_ComplexResponse(
        CborEncoder* e, const ComplexResponse* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "summary");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->summary);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "itemCount");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->itemCount);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "hasNote");
    if (err) return err;
    err = nimffi_enc_bool(&m, &v->hasNote);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_ComplexResponse(
        CborValue* it, ComplexResponse* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "summary", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->summary);
    if (err) return err;
    err = cbor_value_map_find_value(it, "itemCount", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->itemCount);
    if (err) return err;
    err = cbor_value_map_find_value(it, "hasNote", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_bool(&field, &out->hasNote);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_ComplexResponse(ComplexResponse* v) {
    if (!v) return;
    nimffi_free_str(&v->summary);
}
static inline CborError my_timer_enc_EchoEvent(
        CborEncoder* e, const EchoEvent* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "message");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->message);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "echoCount");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->echoCount);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_EchoEvent(
        CborValue* it, EchoEvent* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "message", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->message);
    if (err) return err;
    err = cbor_value_map_find_value(it, "echoCount", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->echoCount);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_EchoEvent(EchoEvent* v) {
    if (!v) return;
    nimffi_free_str(&v->message);
}
static inline CborError my_timer_enc_JobSpec(
        CborEncoder* e, const JobSpec* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "name");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->name);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "payload");
    if (err) return err;
    err = my_timer_enc_MyTimerSeq_Str(&m, &v->payload);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "priority");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->priority);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_JobSpec(
        CborValue* it, JobSpec* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "name", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->name);
    if (err) return err;
    err = cbor_value_map_find_value(it, "payload", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerSeq_Str(&field, &out->payload);
    if (err) return err;
    err = cbor_value_map_find_value(it, "priority", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->priority);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_JobSpec(JobSpec* v) {
    if (!v) return;
    nimffi_free_str(&v->name);
    my_timer_free_MyTimerSeq_Str(&v->payload);
}
static inline CborError my_timer_enc_RetryPolicy(
        CborEncoder* e, const RetryPolicy* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "maxAttempts");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->maxAttempts);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "backoffMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->backoffMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "retryOn");
    if (err) return err;
    err = my_timer_enc_MyTimerSeq_Str(&m, &v->retryOn);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_RetryPolicy(
        CborValue* it, RetryPolicy* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "maxAttempts", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->maxAttempts);
    if (err) return err;
    err = cbor_value_map_find_value(it, "backoffMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->backoffMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "retryOn", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerSeq_Str(&field, &out->retryOn);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_RetryPolicy(RetryPolicy* v) {
    if (!v) return;
    my_timer_free_MyTimerSeq_Str(&v->retryOn);
}
static inline CborError my_timer_enc_ScheduleConfig(
        CborEncoder* e, const ScheduleConfig* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "startAtMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->startAtMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "intervalMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->intervalMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "jitter");
    if (err) return err;
    err = my_timer_enc_MyTimerOpt_I64(&m, &v->jitter);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_ScheduleConfig(
        CborValue* it, ScheduleConfig* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "startAtMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->startAtMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "intervalMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->intervalMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "jitter", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerOpt_I64(&field, &out->jitter);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline CborError my_timer_enc_ScheduleResult(
        CborEncoder* e, const ScheduleResult* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 4);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "jobId");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->jobId);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "willRunCount");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->willRunCount);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "firstRunAtMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->firstRunAtMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "effectiveBackoffMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->effectiveBackoffMs);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_ScheduleResult(
        CborValue* it, ScheduleResult* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "jobId", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->jobId);
    if (err) return err;
    err = cbor_value_map_find_value(it, "willRunCount", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->willRunCount);
    if (err) return err;
    err = cbor_value_map_find_value(it, "firstRunAtMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->firstRunAtMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "effectiveBackoffMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->effectiveBackoffMs);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_ScheduleResult(ScheduleResult* v) {
    if (!v) return;
    nimffi_free_str(&v->jobId);
}
static inline CborError my_timer_enc_MyTimerCreateCtorReq(
        CborEncoder* e, const MyTimerCreateCtorReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "config");
    if (err) return err;
    err = my_timer_enc_TimerConfig(&m, &v->config);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerCreateCtorReq(
        CborValue* it, MyTimerCreateCtorReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "config", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_TimerConfig(&field, &out->config);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_MyTimerCreateCtorReq(MyTimerCreateCtorReq* v) {
    if (!v) return;
    my_timer_free_TimerConfig(&v->config);
}
static inline CborError my_timer_enc_MyTimerEchoReq(
        CborEncoder* e, const MyTimerEchoReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req");
    if (err) return err;
    err = my_timer_enc_EchoRequest(&m, &v->req);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerEchoReq(
        CborValue* it, MyTimerEchoReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "req", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_EchoRequest(&field, &out->req);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_MyTimerEchoReq(MyTimerEchoReq* v) {
    if (!v) return;
    my_timer_free_EchoRequest(&v->req);
}
static inline CborError my_timer_enc_MyTimerVersionReq(
        CborEncoder* e, const MyTimerVersionReq* v) {
    (void)v;
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerVersionReq(
        CborValue* it, MyTimerVersionReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    (void)out;
    return cbor_value_advance(it);
}
static inline CborError my_timer_enc_MyTimerComplexReq(
        CborEncoder* e, const MyTimerComplexReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req");
    if (err) return err;
    err = my_timer_enc_ComplexRequest(&m, &v->req);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerComplexReq(
        CborValue* it, MyTimerComplexReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "req", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_ComplexRequest(&field, &out->req);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_MyTimerComplexReq(MyTimerComplexReq* v) {
    if (!v) return;
    my_timer_free_ComplexRequest(&v->req);
}
static inline CborError my_timer_enc_MyTimerScheduleReq(
        CborEncoder* e, const MyTimerScheduleReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "job");
    if (err) return err;
    err = my_timer_enc_JobSpec(&m, &v->job);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "retry");
    if (err) return err;
    err = my_timer_enc_RetryPolicy(&m, &v->retry);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "schedule");
    if (err) return err;
    err = my_timer_enc_ScheduleConfig(&m, &v->schedule);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerScheduleReq(
        CborValue* it, MyTimerScheduleReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "job", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_JobSpec(&field, &out->job);
    if (err) return err;
    err = cbor_value_map_find_value(it, "retry", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_RetryPolicy(&field, &out->retry);
    if (err) return err;
    err = cbor_value_map_find_value(it, "schedule", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_ScheduleConfig(&field, &out->schedule);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_MyTimerScheduleReq(MyTimerScheduleReq* v) {
    if (!v) return;
    my_timer_free_JobSpec(&v->job);
    my_timer_free_RetryPolicy(&v->retry);
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

void* my_timer_create(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);
int my_timer_echo(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_version(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_complex(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_schedule(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_destroy(void* ctx);
uint64_t my_timer_add_event_listener(void* ctx, const char* event_name, FFICallback callback, void* user_data);
int my_timer_remove_event_listener(void* ctx, uint64_t listener_id);

#ifdef __cplusplus
} /* extern "C" */
#endif

/* CBOR buffer adapters (typed codec → void* driver signature) */
static inline CborError my_timer_encv_MyTimerCreateCtorReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerCreateCtorReq(e, (const MyTimerCreateCtorReq*)v); }
static inline CborError my_timer_encv_MyTimerEchoReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerEchoReq(e, (const MyTimerEchoReq*)v); }
static inline CborError my_timer_encv_MyTimerVersionReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerVersionReq(e, (const MyTimerVersionReq*)v); }
static inline CborError my_timer_encv_MyTimerComplexReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerComplexReq(e, (const MyTimerComplexReq*)v); }
static inline CborError my_timer_encv_MyTimerScheduleReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerScheduleReq(e, (const MyTimerScheduleReq*)v); }
static inline CborError my_timer_decv_EchoResponse(CborValue* it, void* v) { return my_timer_dec_EchoResponse(it, (EchoResponse*)v); }
static inline CborError my_timer_decv_Str(CborValue* it, void* v) { return nimffi_dec_str(it, (NimFfiStr*)v); }
static inline CborError my_timer_decv_ComplexResponse(CborValue* it, void* v) { return my_timer_dec_ComplexResponse(it, (ComplexResponse*)v); }
static inline CborError my_timer_decv_ScheduleResult(CborValue* it, void* v) { return my_timer_dec_ScheduleResult(it, (ScheduleResult*)v); }

/* Event listener machinery */
typedef void (*MyTimerOnEchoFiredFn)(const EchoEvent* evt, void* user_data);
typedef struct { MyTimerOnEchoFiredFn fn; void* user_data; } MyTimerOnEchoFiredBox;
static void my_timer_on_echo_fired_trampoline(int ret, const char* msg, size_t len, void* ud) {
    if (!ud || ret != 0 || !msg || len == 0) return;
    MyTimerOnEchoFiredBox* box = (MyTimerOnEchoFiredBox*)ud;
    if (!box->fn) return;
    CborParser parser;
    CborValue it;
    if (cbor_parser_init((const uint8_t*)msg, len, 0, &parser, &it) != CborNoError) return;
    if (!cbor_value_is_map(&it)) return;
    CborValue payloadField;
    if (cbor_value_map_find_value(&it, "payload", &payloadField) != CborNoError) return;
    EchoEvent payload;
    memset(&payload, 0, sizeof(payload));
    if (my_timer_dec_EchoEvent(&payloadField, &payload) != CborNoError) return;
    box->fn(&payload, box->user_data);
    my_timer_free_EchoEvent(&payload);
}

/* ============================================================ */
/* High-level context wrapper                                   */
/* ============================================================ */
typedef struct {
    uint64_t id;
    void* box;
} MyTimerCtxListener;

typedef struct {
    void* ptr;
    uint32_t timeout_ms;
    MyTimerCtxListener* listeners;
    size_t listeners_len;
    size_t listeners_cap;
} MyTimerCtx;

static inline MyTimerCtx* my_timer_ctx_create(const TimerConfig* config, uint32_t timeout_ms, char** err) {
    if (err) *err = NULL;
    MyTimerCreateCtorReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.config = *config;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerCreateCtorReq, &ffi_req, &req_buf, &req_len, err) != 0) return NULL;
    NimFfiCallState* st = nimffi_state_new();
    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr("out of memory"); return NULL; }
    (void)my_timer_create(req_buf, req_len, nimffi_on_result, st);
    free(req_buf);
    uint8_t* resp = NULL;
    size_t resp_len = 0;
    if (nimffi_wait_result(st, timeout_ms, &resp, &resp_len, err) != 0) return NULL;
    NimFfiStr addr;
    memset(&addr, 0, sizeof(addr));
    if (nimffi_decode_from_buf(my_timer_decv_Str, resp, resp_len, &addr, err) != 0) { free(resp); return NULL; }
    free(resp);
    char* endp = NULL;
    unsigned long long a = addr.data ? strtoull(addr.data, &endp, 10) : 0;
    bool ok = addr.data && addr.len > 0 && endp && *endp == '\0';
    nimffi_free_str(&addr);
    if (!ok) { if (err) *err = nimffi_dup_cstr("FFI create returned non-numeric address"); return NULL; }
    MyTimerCtx* ctx = (MyTimerCtx*)calloc(1, sizeof(MyTimerCtx));
    if (!ctx) { if (err) *err = nimffi_dup_cstr("out of memory"); return NULL; }
    ctx->ptr = (void*)(uintptr_t)a;
    ctx->timeout_ms = timeout_ms;
    return ctx;
}

static inline void my_timer_ctx_destroy(MyTimerCtx* ctx) {
    if (!ctx) return;
    if (ctx->ptr) { my_timer_destroy(ctx->ptr); ctx->ptr = NULL; }
    for (size_t i = 0; i < ctx->listeners_len; i++) free(ctx->listeners[i].box);
    free(ctx->listeners);
    free(ctx);
}

static inline uint64_t my_timer_ctx_add_on_echo_fired_listener(MyTimerCtx* ctx, MyTimerOnEchoFiredFn fn, void* user_data) {
    MyTimerOnEchoFiredBox* box = (MyTimerOnEchoFiredBox*)malloc(sizeof(MyTimerOnEchoFiredBox));
    if (!box) return 0;
    box->fn = fn;
    box->user_data = user_data;
    uint64_t id = my_timer_add_event_listener(ctx->ptr, "on_echo_fired", my_timer_on_echo_fired_trampoline, box);
    if (id == 0) { free(box); return 0; }
    if (ctx->listeners_len == ctx->listeners_cap) {
        size_t ncap = ctx->listeners_cap ? ctx->listeners_cap * 2 : 4;
        MyTimerCtxListener* grown = (MyTimerCtxListener*)realloc(ctx->listeners, ncap * sizeof(MyTimerCtxListener));
        if (!grown) { my_timer_remove_event_listener(ctx->ptr, id); free(box); return 0; }
        ctx->listeners = grown;
        ctx->listeners_cap = ncap;
    }
    ctx->listeners[ctx->listeners_len].id = id;
    ctx->listeners[ctx->listeners_len].box = box;
    ctx->listeners_len++;
    return id;
}

static inline bool my_timer_ctx_remove_event_listener(MyTimerCtx* ctx, uint64_t id) {
    if (id == 0) return false;
    int rc = my_timer_remove_event_listener(ctx->ptr, id);
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

static inline int my_timer_ctx_echo(const MyTimerCtx* ctx, const EchoRequest* req, EchoResponse* out, char** err) {
    if (err) *err = NULL;
    MyTimerEchoReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerEchoReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    NimFfiCallState* st = nimffi_state_new();
    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr("out of memory"); return -1; }
    int ret = my_timer_echo(ctx->ptr, nimffi_on_result, st, req_buf, req_len);
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
    int dec = nimffi_decode_from_buf(my_timer_decv_EchoResponse, resp, resp_len, out, err);
    free(resp);
    if (dec != 0) {
        my_timer_free_EchoResponse(out);
        memset(out, 0, sizeof(*out));
    }
    return dec;
}

static inline int my_timer_ctx_version(const MyTimerCtx* ctx, NimFfiStr* out, char** err) {
    if (err) *err = NULL;
    MyTimerVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerVersionReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    NimFfiCallState* st = nimffi_state_new();
    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr("out of memory"); return -1; }
    int ret = my_timer_version(ctx->ptr, nimffi_on_result, st, req_buf, req_len);
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
    int dec = nimffi_decode_from_buf(my_timer_decv_Str, resp, resp_len, out, err);
    free(resp);
    if (dec != 0) {
        nimffi_free_str(out);
        memset(out, 0, sizeof(*out));
    }
    return dec;
}

static inline int my_timer_ctx_complex(const MyTimerCtx* ctx, const ComplexRequest* req, ComplexResponse* out, char** err) {
    if (err) *err = NULL;
    MyTimerComplexReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerComplexReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    NimFfiCallState* st = nimffi_state_new();
    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr("out of memory"); return -1; }
    int ret = my_timer_complex(ctx->ptr, nimffi_on_result, st, req_buf, req_len);
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
    int dec = nimffi_decode_from_buf(my_timer_decv_ComplexResponse, resp, resp_len, out, err);
    free(resp);
    if (dec != 0) {
        my_timer_free_ComplexResponse(out);
        memset(out, 0, sizeof(*out));
    }
    return dec;
}

static inline int my_timer_ctx_schedule(const MyTimerCtx* ctx, const JobSpec* job, const RetryPolicy* retry, const ScheduleConfig* schedule, ScheduleResult* out, char** err) {
    if (err) *err = NULL;
    MyTimerScheduleReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.job = *job;
    ffi_req.retry = *retry;
    ffi_req.schedule = *schedule;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerScheduleReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    NimFfiCallState* st = nimffi_state_new();
    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr("out of memory"); return -1; }
    int ret = my_timer_schedule(ctx->ptr, nimffi_on_result, st, req_buf, req_len);
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
    int dec = nimffi_decode_from_buf(my_timer_decv_ScheduleResult, resp, resp_len, out, err);
    free(resp);
    if (dec != 0) {
        my_timer_free_ScheduleResult(out);
        memset(out, 0, sizeof(*out));
    }
    return dec;
}

