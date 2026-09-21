#ifndef NIM_FFI_CBOR_HELPERS_H_INCLUDED
#define NIM_FFI_CBOR_HELPERS_H_INCLUDED
/* Leaf CBOR codecs (scalars, text strings, byte strings), the buffer drivers,
 * and what every library's wrapper shares: the reader of a reply and the table
 * of the requests waiting for one. The per-struct / per-container codecs in
 * the library header call into the leaves by name (C has no overloading, so
 * each leaf gets a distinct nimffi_enc_* / nimffi_dec_* symbol). Guarded so two
 * nim-ffi headers can share a translation unit. */
#include "nim_ffi_prelude.h"
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Status codes. A request export returns NIMFFI_RET_OK once the request is
 * queued: exactly one NIMFFI_MSG_REPLY will then carry its id, unless the
 * context closes first. Any other return means the request was refused and no
 * reply will come: NIMFFI_RET_ERR, _INVALID_CTX, _QUEUE_FULL or _TOO_LARGE,
 * with the text in <lib>_last_error().
 *
 * A reply's `ret_code` is NIMFFI_RET_OK (the payload is the CBOR return value)
 * or NIMFFI_RET_ERR (the payload is UTF-8 error text).
 *
 * NIMFFI_RET_TIMEOUT, _CLOSED and _BUSY come from <lib>_poll(), and so from
 * the pump and the `_sync` helpers built on it; see its comment in <lib>.h. */
{{RET_CODES}}

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
static inline CborError nimffi_enc_str(CborEncoder* e, const char* const* v) {
    return cbor_encode_text_stringz(e, *v ? *v : "");
}
static inline CborError nimffi_enc_bytes(CborEncoder* e, const NimFfiBytes* v) {
    /* A null src is UB in memcpy even for len 0, and UBSan reports it. */
    static const uint8_t nimffi_empty_byte = 0;
    return cbor_encode_byte_string(e, v->len != 0 ? v->data : &nimffi_empty_byte, v->len);
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
    if (tmp < INT32_MIN || tmp > INT32_MAX) {
        return CborErrorDataTooLarge;
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
    if (tmp < INT16_MIN || tmp > INT16_MAX) {
        return CborErrorDataTooLarge;
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
    if (tmp < INT8_MIN || tmp > INT8_MAX) {
        return CborErrorDataTooLarge;
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
    if (tmp > UINT32_MAX) {
        return CborErrorDataTooLarge;
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
    if (tmp > UINT16_MAX) {
        return CborErrorDataTooLarge;
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
    if (tmp > UINT8_MAX) {
        return CborErrorDataTooLarge;
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
static inline CborError nimffi_dec_str(CborValue* it, const char** out) {
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
    char* buf = (char*)malloc(len + 1); /* + the NUL terminator */
    if (!buf) {
        return CborErrorOutOfMemory;
    }
    size_t copied = len;
    err = cbor_value_copy_text_string(it, buf, &copied, NULL);
    if (err) {
        free(buf);
        return err;
    }
    buf[len] = '\0';
    *out = buf;
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
 * for turning the error text of a message's payload into a C string; NULL if
 * it can't. */
static inline char* nimffi_dup_cstr_n(const char* s, size_t n) {
    if (n == SIZE_MAX) {
        return NULL;
    }
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

/* ── replies ───────────────────────────────────────────────────────────── */
/* Reads the status of a NIMFFI_MSG_REPLY. Returns NIMFFI_RET_OK;
 * NIMFFI_RET_ERR with the library's error text in `*err`; or -1 when `msg` is
 * not a reply. `*err` is a NUL-terminated copy the caller frees; `err` may be
 * NULL. */
static inline int nimffi_reply_status(const NimFfiMsg* msg, char** err) {
    if (err) *err = NULL;
    if (!msg || msg->kind != NIMFFI_MSG_REPLY) {
        if (err) *err = nimffi_dup_cstr("not a reply");
        return -1;
    }
    if (msg->ret_code != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr_n((const char*)msg->payload, msg->len);
        return NIMFFI_RET_ERR;
    }
    return NIMFFI_RET_OK;
}

/* nimffi_reply_status(), then the payload decoded into `out` with `fn`; -1
 * also when it does not decode. */
static inline int nimffi_decode_reply(
        const NimFfiMsg* msg, nimffi_dec_fn fn, void* out, char** err) {
    if (!out) {
        if (err) *err = nimffi_dup_cstr("out is NULL");
        return -1;
    }
    int rc = nimffi_reply_status(msg, err);
    if (rc != NIMFFI_RET_OK) {
        return rc;
    }
    return nimffi_decode_from_buf(fn, msg->payload, msg->len, out, err);
}

/* ── requests waiting for their reply ──────────────────────────────────── */
/* The library calls nothing back: the binding remembers who asked, and the
 * dispatch of a NIMFFI_MSG_REPLY looks the request id up here. Not locked: a
 * table belongs to the one thread that submits and pumps its context. */

/* Any typed reply callback; cast back to its own type before it is called. */
typedef void (*nimffi_generic_fn)(void);

/* Settles one request. `msg` is its reply, or NULL when the context closed
 * before it was answered. */
typedef void (*nimffi_settle_fn)(
        const NimFfiMsg* msg, nimffi_generic_fn on_reply, void* user_data);

typedef struct {
    uint64_t req_id;
    nimffi_settle_fn settle;
    nimffi_generic_fn on_reply;
    void* user_data;
} NimFfiPendingEntry;

typedef struct {
    NimFfiPendingEntry* items;
    size_t len;
    size_t cap;
} NimFfiPending;

/* Where a `_sync` helper waits for its reply. */
typedef struct {
    bool done;
    int ret;
    void* out;
    char** err;
} NimFfiSyncSlot;

/* Settles a `_sync` slot whose context closed before the reply. */
static inline void nimffi_sync_slot_closed(NimFfiSyncSlot* slot) {
    slot->ret = NIMFFI_RET_CLOSED;
    if (slot->err) *slot->err = nimffi_dup_cstr("context closed");
    slot->done = true;
}

/* Makes room for one more entry. Called before the submit, so that a request
 * the library accepted can always be recorded. Returns 0, or -1 when out of
 * memory. */
static inline int nimffi_pending_reserve(NimFfiPending* p) {
    if (p->len < p->cap) {
        return 0;
    }
    size_t cap = p->cap ? p->cap * 2 : 8;
    NimFfiPendingEntry* grown =
        (NimFfiPendingEntry*)realloc(p->items, cap * sizeof(NimFfiPendingEntry));
    if (!grown) {
        return -1;
    }
    p->items = grown;
    p->cap = cap;
    return 0;
}

/* After nimffi_pending_reserve(): cannot fail. */
static inline void nimffi_pending_add(NimFfiPending* p, NimFfiPendingEntry entry) {
    p->items[p->len++] = entry;
}

/* Removes the entry of `req_id` into `*out`. False for an id nobody waits for:
 * an abandoned request, or one another binding submitted. */
static inline bool nimffi_pending_take(
        NimFfiPending* p, uint64_t req_id, NimFfiPendingEntry* out) {
    for (size_t i = 0; i < p->len; i++) {
        if (p->items[i].req_id == req_id) {
            *out = p->items[i];
            p->items[i] = p->items[--p->len];
            return true;
        }
    }
    return false;
}

/* Forgets `req_id`: its late reply is then dropped instead of settled. */
static inline void nimffi_pending_abandon(NimFfiPending* p, uint64_t req_id) {
    NimFfiPendingEntry dropped;
    (void)nimffi_pending_take(p, req_id, &dropped);
}

/* The context closed: no reply will come, so every waiting request is settled
 * without one. The table is detached first because a callback may submit. */
static inline void nimffi_pending_close(NimFfiPending* p) {
    NimFfiPendingEntry* items = p->items;
    size_t len = p->len;
    p->items = NULL;
    p->len = 0;
    p->cap = 0;
    for (size_t i = 0; i < len; i++) {
        items[i].settle(NULL, items[i].on_reply, items[i].user_data);
    }
    free(items);
}

/* Milliseconds of a clock that only moves forward, for the `_sync` timeouts. */
static inline int64_t nimffi_now_ms(void) {
#if defined(_WIN32)
    /* The CRT's clock() counts wall time since the process started. */
    return (int64_t)clock() * 1000 / CLOCKS_PER_SEC;
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + (int64_t)(t.tv_nsec / (1000 * 1000));
#endif
}

/* One definition per program for an object a header defines: the table of the
 * static context must be the same in every translation unit. */
#if defined(_WIN32)
#  define NIMFFI_SHARED __declspec(selectany)
#else
#  define NIMFFI_SHARED __attribute__((weak))
#endif

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_CBOR_HELPERS_H_INCLUDED */
