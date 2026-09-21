#pragma once
// Generated bindings require C++20 (designated initializers and other
// C++20 constructs are used throughout the emitted code).
// MSVC keeps __cplusplus at 199711L unless /Zc:__cplusplus is passed,
// so consult _MSVC_LANG when present (it always reflects the active
// /std:c++XX level).
#if defined(_MSVC_LANG)
#  if _MSVC_LANG < 202002L
#    error "nim-ffi generated headers require C++20 or later (use /std:c++20)"
#  endif
#elif !defined(__cplusplus) || __cplusplus < 202002L
#  error "nim-ffi generated headers require C++20 or later"
#endif
#include <string>
#include <cstdint>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <map>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <memory>
#include <functional>
#include <future>
#include <vector>
#include <optional>
#include <type_traits>
#include <unordered_map>
#include <cstring>
#include <cassert>
extern "C" {
#include <tinycbor/cbor.h>
}

// nim-ffi status codes (mirror ffi/ret_codes.nim and the C header). Guarded so
// a translation unit that also pulls in the C header keeps a single definition.
#ifndef NIMFFI_RET_OK
#define NIMFFI_RET_OK 0
#define NIMFFI_RET_ERR 1
#define NIMFFI_RET_TIMEOUT 4
#define NIMFFI_RET_CLOSED 5
#define NIMFFI_RET_INVALID_CTX 6
#define NIMFFI_RET_BUSY 7
#define NIMFFI_RET_QUEUE_FULL 8
#define NIMFFI_RET_TOO_LARGE 9
#endif

// ============================================================
// Result<T> — exception-free error channel
// ============================================================
// The generated bindings never throw: every fallible entry point (create,
// instance methods, and their *Async futures) returns a Result<T>. Callers
// branch on isOk()/isErr() (or the explicit bool conversion) and read
// value()/error(). This mirrors the Nim side's Result[T, string] and keeps
// us off C++23's std::expected.
#ifndef NIM_FFI_RESULT_HPP_INCLUDED
#define NIM_FFI_RESULT_HPP_INCLUDED

template <typename T>
class Result {
    std::optional<T> value_;
    std::string error_;
public:
    static Result<T> ok(T value) {
        Result<T> r;
        r.value_ = std::move(value);
        return r;
    }
    static Result<T> err(std::string message) {
        Result<T> r;
        r.error_ = std::move(message);
        return r;
    }
    bool isOk() const { return value_.has_value(); }
    bool isErr() const { return !value_.has_value(); }
    explicit operator bool() const { return isOk(); }
    const T& value() const         { assert(value_.has_value() && "Result::value() called on err Result — check isOk() first"); return *value_; }
    T& value()                     { assert(value_.has_value() && "Result::value() called on err Result — check isOk() first"); return *value_; }
    const T& operator*() const     { assert(value_.has_value() && "Result::operator*() called on err Result — check isOk() first"); return *value_; }
    const T* operator->() const    { assert(value_.has_value() && "Result::operator->() called on err Result — check isOk() first"); return &*value_; }
    T&& take()                     { assert(value_.has_value() && "Result::take() called on err Result — check isOk() first"); return std::move(*value_); }
    const std::string& error() const { assert(!value_.has_value() && "Result::error() called on ok Result — check isErr() first"); return error_; }
};

template <>
class Result<void> {
    bool ok_ = true;
    std::string error_;
public:
    static Result<void> ok() {
        Result<void> r;
        r.ok_ = true;
        return r;
    }
    static Result<void> err(std::string message) {
        Result<void> r;
        r.ok_ = false;
        r.error_ = std::move(message);
        return r;
    }
    Result() = default;
    bool isOk() const { return ok_; }
    bool isErr() const { return !ok_; }
    explicit operator bool() const { return isOk(); }
    const std::string& error() const { assert(!ok_ && "Result<void>::error() called on ok Result — check isErr() first"); return error_; }
};

#endif // NIM_FFI_RESULT_HPP_INCLUDED

// ── encode_cbor overloads (primitives + containers) ─────────────────────
// Per-struct encode_cbor / decode_cbor are emitted by cpp.nim next to each
// generated struct; these helpers cover the leaf types they defer into.
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_CBOR_HELPERS_HPP_INCLUDED
#define NIM_FFI_CBOR_HELPERS_HPP_INCLUDED

inline CborError encode_cbor(CborEncoder& e, bool v) {
    return cbor_encode_boolean(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, int64_t v) {
    return cbor_encode_int(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, int32_t v) {
    return cbor_encode_int(&e, static_cast<int64_t>(v));
}
inline CborError encode_cbor(CborEncoder& e, uint64_t v) {
    return cbor_encode_uint(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, double v) {
    return cbor_encode_double(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, const std::string& v) {
    return cbor_encode_text_string(&e, v.data(), v.size());
}

template<typename T>
inline CborError encode_cbor(CborEncoder& e, const std::vector<T>& v) {
    CborEncoder arr;
    CborError err = cbor_encoder_create_array(&e, &arr, v.size());
    if (err) return err;
    for (const auto& item : v) {
        err = encode_cbor(arr, item);
        if (err) return err;
    }
    return cbor_encoder_close_container(&e, &arr);
}

// `seq[byte]` rides the wire as a CBOR byte string (major type 2), matching
// Nim's cbor_serialization. This non-template overload beats the std::vector<T>
// template in overload resolution, so std::vector<std::uint8_t> fields use it
// automatically.
inline CborError encode_cbor(CborEncoder& e, const std::vector<std::uint8_t>& v) {
    // An empty vector's data() is null, and a null src is UB in memcpy even for size 0.
    static const std::uint8_t empty = 0;
    return cbor_encode_byte_string(&e, v.empty() ? &empty : v.data(), v.size());
}

template<typename T>
inline CborError encode_cbor(CborEncoder& e, const std::optional<T>& v) {
    if (!v) return cbor_encode_null(&e);
    return encode_cbor(e, *v);
}

// ── decode_cbor overloads ───────────────────────────────────────────────

// After reading a leaf value, the parser must advance past it; both steps
// short-circuit on the same CborError, so they always travel together.
inline CborError advance_if_ok(CborValue& it, CborError err) {
    if (err) return err;
    return cbor_value_advance(&it);
}

inline CborError decode_cbor(CborValue& it, bool& out) {
    if (!cbor_value_is_boolean(&it)) return CborErrorImproperValue;
    return advance_if_ok(it, cbor_value_get_boolean(&it, &out));
}
inline CborError decode_cbor(CborValue& it, int64_t& out) {
    if (!cbor_value_is_integer(&it)) return CborErrorImproperValue;
    return advance_if_ok(it, cbor_value_get_int64_checked(&it, &out));
}
inline CborError decode_cbor(CborValue& it, int32_t& out) {
    int64_t tmp = 0;
    CborError err = decode_cbor(it, tmp);
    if (err) return err;
    out = static_cast<int32_t>(tmp);
    return CborNoError;
}
inline CborError decode_cbor(CborValue& it, uint64_t& out) {
    if (!cbor_value_is_unsigned_integer(&it)) return CborErrorImproperValue;
    return advance_if_ok(it, cbor_value_get_uint64(&it, &out));
}
inline CborError decode_cbor(CborValue& it, double& out) {
    if (cbor_value_is_double(&it)) {
        return advance_if_ok(it, cbor_value_get_double(&it, &out));
    }
    if (cbor_value_is_float(&it)) {
        float f = 0.0f;
        CborError err = cbor_value_get_float(&it, &f);
        if (err) return err;
        out = static_cast<double>(f);
        return cbor_value_advance(&it);
    }
    return CborErrorImproperValue;
}
inline CborError decode_cbor(CborValue& it, std::string& out) {
    if (!cbor_value_is_text_string(&it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_string_length(&it, &len);
    if (err) return err;
    out.resize(len);
    return advance_if_ok(
        it, cbor_value_copy_text_string(&it, out.empty() ? nullptr : &out[0], &len, nullptr));
}

template<typename T>
inline CborError decode_cbor(CborValue& it, std::vector<T>& out) {
    if (!cbor_value_is_array(&it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_array_length(&it, &len);
    if (err) return err;
    out.clear();
    out.resize(len);
    CborValue inner;
    err = cbor_value_enter_container(&it, &inner);
    if (err) return err;
    for (size_t i = 0; i < len; ++i) {
        err = decode_cbor(inner, out[i]);
        if (err) return err;
    }
    return cbor_value_leave_container(&it, &inner);
}

// Counterpart to the byte-string encoder above: decode a CBOR byte string
// (major type 2) back into std::vector<std::uint8_t>.
inline CborError decode_cbor(CborValue& it, std::vector<std::uint8_t>& out) {
    if (!cbor_value_is_byte_string(&it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_string_length(&it, &len);
    if (err) return err;
    out.resize(len);
    return advance_if_ok(
        it, cbor_value_copy_byte_string(&it, out.empty() ? nullptr : out.data(), &len, nullptr));
}

template<typename T>
inline CborError decode_cbor(CborValue& it, std::optional<T>& out) {
    if (cbor_value_is_null(&it)) {
        out = std::nullopt;
        return cbor_value_advance(&it);
    }
    T tmp{};
    CborError err = decode_cbor(it, tmp);
    if (err) return err;
    out = std::move(tmp);
    return CborNoError;
}

// ── Public entry points ─────────────────────────────────────────────────

template<typename T>
inline Result<std::vector<std::uint8_t>> encodeCborFFI(const T& value) {
    // Start with a generous 4 KiB buffer; double on overflow until it fits.
    std::vector<std::uint8_t> buf(4096);
    while (true) {
        CborEncoder enc;
        cbor_encoder_init(&enc, buf.data(), buf.size(), 0);
        CborError err = encode_cbor(enc, value);
        if (err == CborNoError) {
            const size_t used = cbor_encoder_get_buffer_size(&enc, buf.data());
            buf.resize(used);
            return Result<std::vector<std::uint8_t>>::ok(std::move(buf));
        }
        if (err == CborErrorOutOfMemory) {
            const size_t extra = cbor_encoder_get_extra_bytes_needed(&enc);
            buf.resize(buf.size() + (extra > 0 ? extra : buf.size()));
            continue;
        }
        return Result<std::vector<std::uint8_t>>::err(
            std::string("FFI CBOR encode failed: ") + cbor_error_string(err));
    }
}

template<typename T>
inline Result<T> decodeCborFFI(const std::vector<std::uint8_t>& bytes) {
    CborParser parser;
    CborValue it;
    CborError err = cbor_parser_init(bytes.data(), bytes.size(), 0, &parser, &it);
    if (err != CborNoError) {
        return Result<T>::err(std::string("FFI CBOR parse init failed: ") +
                              cbor_error_string(err));
    }
    T out{};
    err = decode_cbor(it, out);
    if (err != CborNoError) {
        return Result<T>::err(std::string("FFI CBOR decode failed: ") +
                              cbor_error_string(err));
    }
    return Result<T>::ok(std::move(out));
}

#endif // NIM_FFI_CBOR_HELPERS_HPP_INCLUDED

// ============================================================
// Generated constants
// ============================================================

constexpr int64_t MAX_SHOUT_LEN = 512;

// ============================================================
// User-declared FFI types
// ============================================================

struct EchoConfig {
    std::string prefix;
};
inline CborError encode_cbor(CborEncoder& e, const EchoConfig& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "prefix"); if (err) return err;
    err = encode_cbor(m, v.prefix);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoConfig& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "prefix", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.prefix); if (err) return err;
    return cbor_value_advance(&it);
}

struct ShoutRequest {
    std::string text;
};
inline CborError encode_cbor(CborEncoder& e, const ShoutRequest& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "text"); if (err) return err;
    err = encode_cbor(m, v.text);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, ShoutRequest& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "text", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.text); if (err) return err;
    return cbor_value_advance(&it);
}

struct ShoutResponse {
    std::string shouted;
    std::string prefix;
};
inline CborError encode_cbor(CborEncoder& e, const ShoutResponse& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "shouted"); if (err) return err;
    err = encode_cbor(m, v.shouted);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "prefix"); if (err) return err;
    err = encode_cbor(m, v.prefix);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, ShoutResponse& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "shouted", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.shouted); if (err) return err;
    err = cbor_value_map_find_value(&it, "prefix", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.prefix); if (err) return err;
    return cbor_value_advance(&it);
}

// ============================================================
// Per-proc request envelopes (CBOR encoded on the wire)
// ============================================================

struct EchoCreateCtorReq {
    EchoConfig config;
};
inline CborError encode_cbor(CborEncoder& e, const EchoCreateCtorReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "config"); if (err) return err;
    err = encode_cbor(m, v.config);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoCreateCtorReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "config", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.config); if (err) return err;
    return cbor_value_advance(&it);
}

struct EchoShoutReq {
    ShoutRequest req;
};
inline CborError encode_cbor(CborEncoder& e, const EchoShoutReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req"); if (err) return err;
    err = encode_cbor(m, v.req);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoShoutReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "req", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.req); if (err) return err;
    return cbor_value_advance(&it);
}

struct EchoVersionReq {
};
inline CborError encode_cbor(CborEncoder& e, const EchoVersionReq&) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoVersionReq&) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    return cbor_value_advance(&it);
}

struct EchoLibVersionReq {
};
inline CborError encode_cbor(CborEncoder& e, const EchoLibVersionReq&) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoLibVersionReq&) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    return cbor_value_advance(&it);
}

struct EchoShoutAnonReq {
    ShoutRequest req;
};
inline CborError encode_cbor(CborEncoder& e, const EchoShoutAnonReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req"); if (err) return err;
    err = encode_cbor(m, v.req);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoShoutAnonReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "req", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.req); if (err) return err;
    return cbor_value_advance(&it);
}

// ============================================================
// Messages from the library
// ============================================================
// What `<lib>_poll` hands out (mirrors ffi/ffi_msg.nim and the C header).
// Guarded so a translation unit that pulls in a second nim-ffi header, or the
// C header, keeps a single definition.
#ifndef NIMFFI_MSG_EVENT
extern "C" {
#ifndef NIMFFI_MSG_DECLARED
#define NIMFFI_MSG_DECLARED
typedef struct {
  uint32_t struct_size;   /* sizeof(NimFfiMsg) of the library; fields are only appended */
  uint32_t kind;          /* NIMFFI_MSG_* */
  uint64_t seq;           /* production order within the context */
  uint64_t id;            /* REPLY, STALE_WARN: the request id. Otherwise 0 */
  uint64_t name_id;       /* EVENT: which one. Otherwise 0 */
  uint64_t aux;
  int32_t  ret_code;
  uint32_t flags;
  const uint8_t* payload; /* bare CBOR value; never NULL */
  size_t   len;
} NimFfiMsg;

#define NIMFFI_MSG_REPLY 1  /* id is the request; ret_code OK: payload is its CBOR, ERR: UTF-8 text */
#define NIMFFI_MSG_STALE_WARN 3  /* request id is still running after aux ms; its REPLY still comes */
#define NIMFFI_MSG_EVENT 2  /* name_id names it; payload is its CBOR */
#define NIMFFI_MSG_NOT_RESPONDING 5  /* aux is a NIMFFI_NOT_RESPONDING_* reason */
#define NIMFFI_MSG_RESPONDING 6  /* the FFI thread's heartbeat resumed */
#define NIMFFI_MSG_CLOSED 7  /* the context is gone; every later poll fails */

#define NIMFFI_NOT_RESPONDING_HEARTBEAT 1
#define NIMFFI_NOT_RESPONDING_EVENT_QUEUE_FULL 2
#endif /* NIMFFI_MSG_DECLARED */
} // extern "C"
#endif // NIMFFI_MSG_EVENT

// ============================================================
// C FFI declarations
// ============================================================

extern "C" {
/**
 * A request returns as soon as it is queued. NIMFFI_RET_OK promises exactly one
 * NIMFFI_MSG_REPLY out of `<lib>_poll` whose `id` is `*req_id_out`, unless the
 * context closes first; the reply can be polled before the request call returns.
 * Any other return means no reply will come; `<lib>_last_error` says why.
 * A reply's `ret_code` is NIMFFI_RET_OK and its payload the CBOR return value, or
 * NIMFFI_RET_ERR and its payload UTF-8 error text.
 * The constructor sets `*ctx_out` at once, so it can be polled; whether the
 * construction worked is the reply `*req_id_out` on it. After a NIMFFI_RET_ERR
 * reply the context is still claimed and must be destroyed.
 * The context class below does all of this: one typed method per request.
 */

/** Creates an echo context that prefixes every reply with `config.prefix`. */
int echo_create(const uint8_t* req_cbor, size_t req_cbor_len, void** ctx_out, uint64_t* req_id_out);
/** Upper-cases `req.text` and returns it behind the context's prefix. */
int echo_shout(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
/** Returns the library's version string. */
int echo_version(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
int echo_lib_version(const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
int echo_shout_anon(const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
/** Releases the echo context. */
int echo_destroy(void* ctx);
/** The context the replies of the static procs arrive on; NULL on failure. */
void* echo_static_ctx(void);
/** Why the last request of the calling thread was refused. Never NULL. */
const char* echo_last_error(void);
/**
 * Take the next message of `ctx` out, waiting up to `timeout_ms` (0 never
 * blocks, negative waits until a message or the end of the context).
 * NIMFFI_RET_OK: `*msg` is set. The message and its payload belong to the library
 * and stay valid until the next poll on `ctx`.
 * NIMFFI_RET_TIMEOUT: nothing arrived in time.
 * NIMFFI_RET_CLOSED: the context ended; `*msg` is a NIMFFI_MSG_CLOSED whose
 * `ret_code` is NIMFFI_RET_OK, or NIMFFI_RET_ERR with the reason as UTF-8 payload.
 * NIMFFI_RET_INVALID_CTX: `ctx` names no live context.
 * NIMFFI_RET_BUSY: another thread is polling `ctx`; there is one consumer at a time.
 * The context class below already polls from its dispatch thread.
 */
int echo_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);
/**
 * A handle that is ready while a message waits or `ctx` is closed: an epoll fd
 * on Linux, a kqueue fd on macOS/BSD, an Event HANDLE on Windows, -1 on failure.
 * The caller owns it and closes it. Wait on it, then poll with a timeout of 0
 * until NIMFFI_RET_TIMEOUT.
 */
intptr_t echo_poll_fd(void* ctx);
/**
 * Stop every context the library still holds and join their threads.
 * Call it before the process exits when a context is still alive, or when a
 * static proc built the shared context.
 * Returns 0 when every context stopped, 1 when one was left running.
 */
int echo_shutdown(void);
} // extern "C"

// ============================================================
// Message dispatch
// ============================================================
// The library never calls into the host. Each context owns one dispatch thread that
// takes everything the library sends out through `<lib>_poll`: a reply goes to
// the call waiting for it, anything else to the listeners registered for it.
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_DISPATCHER_HPP_INCLUDED
#define NIM_FFI_DISPATCHER_HPP_INCLUDED

class NimFfiDispatcher : public std::enable_shared_from_this<NimFfiDispatcher> {
public:
    using Bytes = std::vector<std::uint8_t>;
    using PollFn = int (*)(void* ctx, std::int32_t timeout_ms, const NimFfiMsg** msg);
    using LastErrorFn = const char* (*)();
    // Decodes one NIMFFI_MSG_EVENT and delivers it; generated per library.
    using EventFn = void (*)(NimFfiDispatcher& dispatcher, const NimFfiMsg& msg);
    // What a reply (or the lack of one) resolves to. Runs on the dispatch thread, so
    // it holds no user code: it decodes and hands the value over.
    using Completion = std::function<void(Result<Bytes>)>;

    using StaleWarnFn = std::function<void(std::uint64_t reqId, std::uint64_t elapsedMs)>;
    using NotRespondingFn = std::function<void(std::uint64_t reason)>;
    using RespondingFn = std::function<void()>;
    using ClosedFn = std::function<void(bool ok, const std::string& reason)>;

    NimFfiDispatcher(PollFn poll, LastErrorFn lastError, void* ctx, EventFn onEvent)
        : poll_(poll), lastError_(lastError), ctx_(ctx), onEvent_(onEvent) {}

    // False when the thread could not be started.
    bool start() noexcept {
        try {
            auto self = shared_from_this();
            std::lock_guard<std::mutex> lock(threadMtx_);
            thread_ = std::thread([self] {
                // `thread_` is assigned by now: `stop` may run on this thread.
                { std::lock_guard<std::mutex> started(self->threadMtx_); }
                self->run();
            });
            return true;
        } catch (...) {
            return false;
        }
    }

    // Joins the dispatch thread. Called on the dispatch thread itself (a listener is
    // destroying its context) it detaches instead, and no listener runs once
    // the handler in flight returns.
    void stop() {
        const bool onOwnThread = onDispatchThread();
        if (onOwnThread) detached_.store(true);
        stop_.store(true);
        std::thread thread;
        {
            std::lock_guard<std::mutex> lock(threadMtx_);
            thread = std::move(thread_);
        }
        if (!thread.joinable()) return;
        if (onOwnThread) thread.detach();
        else thread.join();
    }

    // True once the dispatch thread is over: no reply will be delivered any more.
    bool finished() {
        std::lock_guard<std::mutex> lock(waitMtx_);
        return finished_;
    }

    static std::string refusal(LastErrorFn lastError, int rc) {
        const char* text = lastError ? lastError() : nullptr;
        if (text && *text) return text;
        return "FFI request refused (ret code " + std::to_string(rc) + ")";
    }

    template <class T>
    static std::future<Result<T>> ready(Result<T> value) {
        std::promise<Result<T>> promise;
        auto future = promise.get_future();
        promise.set_value(std::move(value));
        return future;
    }

    // Blocking request. `send(&id)` is the `<lib>_<proc>` call.
    template <class T, class Send>
    Result<T> call(Send&& send, std::chrono::milliseconds timeout) {
        auto state = std::make_shared<SyncState>();
        std::uint64_t id = 0;
        std::string refused = submit(send, timeout, false, syncCompletion(state), id);
        if (!refused.empty()) return Result<T>::err(std::move(refused));
        auto raw = wait(*state, id, timeout);
        if (raw.isErr()) return Result<T>::err(raw.error());
        return decodeCborFFI<T>(raw.value());
    }

    // The future is fulfilled by the dispatch thread, or failed by it once `timeout`
    // passed or the context closed. No thread is started.
    template <class T, class Send>
    std::future<Result<T>> callAsync(Send&& send, std::chrono::milliseconds timeout) {
        auto promise = std::make_shared<std::promise<Result<T>>>();
        auto future = promise->get_future();
        std::uint64_t id = 0;
        std::string refused = submit(send, timeout, true, [promise](Result<Bytes> raw) {
            auto out = Result<T>::err("the FFI reply could not be decoded");
            try {
                if (raw.isErr()) out = Result<T>::err(raw.error());
                else out = decodeCborFFI<T>(raw.value());
            } catch (...) {
            }
            try {
                promise->set_value(std::move(out));
            } catch (...) {
            }
        }, id);
        if (!refused.empty()) promise->set_value(Result<T>::err(std::move(refused)));
        return future;
    }

    // The constructor's reply: its id is known before the dispatch loop runs, so the
    // waiter is in place before the reply can be taken out.
    Result<Bytes> startAndWait(std::uint64_t id, std::chrono::milliseconds timeout) {
        auto state = std::make_shared<SyncState>();
        expect(id, timeout, false, syncCompletion(state));
        if (!start()) {
            abandon("could not start the dispatch thread");
        }
        return wait(*state, id, timeout);
    }

    void startAndThen(std::uint64_t id, std::chrono::milliseconds timeout, Completion done) {
        expect(id, timeout, true, std::move(done));
        if (!start()) abandon("could not start the dispatch thread");
    }

    // 0 when `fn` is empty.
    template <class Fn>
    std::uint64_t add(std::uint32_t kind, std::uint64_t nameId, Fn fn) {
        if (!fn) return 0;
        auto held = std::make_shared<Fn>(std::move(fn));
        std::lock_guard<std::mutex> lock(mtx_);
        const std::uint64_t id = nextId_++;
        listeners_.emplace(id, Listener{kind, nameId, std::move(held)});
        return id;
    }

    bool remove(std::uint64_t id) {
        std::shared_ptr<void> released; // a handler's captures die outside the lock
        std::lock_guard<std::mutex> lock(mtx_);
        auto it = listeners_.find(id);
        if (it == listeners_.end()) return false;
        released = std::move(it->second.fn);
        listeners_.erase(it);
        return true;
    }

    // The payload is decoded in full before any handler runs: `msg` belongs to
    // the library and a handler may end the context or poll again.
    template <class T>
    void deliverEvent(const NimFfiMsg& msg) {
        using Fn = std::function<void(const T&)>;
        const auto fns = matching<Fn>(NIMFFI_MSG_EVENT, msg.name_id);
        if (fns.empty()) return;
        CborParser parser;
        CborValue it;
        if (cbor_parser_init(msg.payload, msg.len, 0, &parser, &it) != CborNoError) return;
        T payload{};
        if (decode_cbor(it, payload) != CborNoError) return;
        call(fns, payload);
    }

private:
    static constexpr std::int32_t SliceMs = 250;
    static constexpr const char* ClosedText = "context closed before the reply arrived";

    struct Listener {
        std::uint32_t kind;
        std::uint64_t nameId;
        std::shared_ptr<void> fn; // the std::function type that `kind`/`nameId` imply
    };

    struct Waiter {
        std::chrono::steady_clock::time_point deadline;
        std::chrono::milliseconds timeout;
        bool swept; // the dispatch thread fails it at `deadline`; a blocking caller times itself out
        Completion done;
    };

    struct SyncState {
        std::mutex mtx;
        std::condition_variable cv;
        bool done{false};
        Result<Bytes> result;
    };

    static Completion syncCompletion(const std::shared_ptr<SyncState>& state) {
        return [state](Result<Bytes> raw) {
            std::lock_guard<std::mutex> lock(state->mtx);
            state->result = std::move(raw);
            state->done = true;
            state->cv.notify_all();
        };
    }

    static std::string timeoutText(std::chrono::milliseconds timeout) {
        return "FFI call timed out after " + std::to_string(timeout.count()) + "ms";
    }

    // Clamped: a caller's "forever" must not overflow the clock arithmetic.
    static std::chrono::milliseconds clamp(std::chrono::milliseconds timeout) {
        constexpr std::chrono::milliseconds Max = std::chrono::hours(24 * 365);
        return std::min(std::max(timeout, std::chrono::milliseconds(0)), Max);
    }

    static NimFfiDispatcher*& current() {
        thread_local NimFfiDispatcher* dispatcher = nullptr;
        return dispatcher;
    }

    bool onDispatchThread() { return current() == this; }

    // Empty: the request is queued and `done` runs exactly once. Otherwise why
    // it was refused; `done` never runs.
    // The lock is held across `send`: the reply can be polled before `send`
    // returns, and the dispatch thread takes this lock before it looks a waiter up.
    template <class Send>
    std::string submit(Send& send, std::chrono::milliseconds timeout, bool swept,
                       Completion done, std::uint64_t& id) {
        std::lock_guard<std::mutex> lock(waitMtx_);
        if (finished_) return ClosedText;
        const int rc = send(&id);
        if (rc != NIMFFI_RET_OK) return refusal(lastError_, rc);
        try {
            waiters_.emplace(id, Waiter{std::chrono::steady_clock::now() + clamp(timeout),
                                        timeout, swept, std::move(done)});
        } catch (...) {
            return "out of memory"; // its reply is dropped like any unknown id
        }
        return {};
    }

    void expect(std::uint64_t id, std::chrono::milliseconds timeout, bool swept,
                Completion done) {
        std::lock_guard<std::mutex> lock(waitMtx_);
        waiters_.emplace(id, Waiter{std::chrono::steady_clock::now() + clamp(timeout),
                                    timeout, swept, std::move(done)});
    }

    // False when the waiter is already gone: its completion ran or is running.
    bool forget(std::uint64_t id) {
        Waiter dropped; // its captures die outside the lock
        std::lock_guard<std::mutex> lock(waitMtx_);
        auto it = waiters_.find(id);
        if (it == waiters_.end()) return false;
        dropped = std::move(it->second);
        waiters_.erase(it);
        return true;
    }

    Result<Bytes> wait(SyncState& state, std::uint64_t id, std::chrono::milliseconds timeout) {
        if (onDispatchThread()) {
            // A listener is calling in: only this thread can take the reply out,
            // so poll here, dispatching whatever else arrives meanwhile.
            const auto deadline = std::chrono::steady_clock::now() + clamp(timeout);
            while (!stop_.load() && !closed_) {
                {
                    std::lock_guard<std::mutex> lock(state.mtx);
                    if (state.done) break;
                }
                const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                    deadline - std::chrono::steady_clock::now()).count();
                if (left <= 0) break;
                dispatchOnce(static_cast<std::int32_t>(std::min<long long>(left, SliceMs)));
            }
        } else {
            std::unique_lock<std::mutex> lock(state.mtx);
            state.cv.wait_for(lock, clamp(timeout), [&] { return state.done; });
        }
        std::unique_lock<std::mutex> lock(state.mtx);
        if (!state.done) {
            lock.unlock();
            if (forget(id)) {
                if (stop_.load()) return Result<Bytes>::err(ClosedText);
                return Result<Bytes>::err(timeoutText(timeout));
            }
            lock.lock(); // the dispatch thread holds the waiter: its completion is imminent
            state.cv.wait(lock, [&] { return state.done; });
        }
        return std::move(state.result);
    }

    static void finish(Waiter& waiter, Result<Bytes> result) {
        try {
            waiter.done(std::move(result));
        } catch (...) {
        }
    }

    // A reply nobody waits for (its caller timed out) is dropped.
    void deliverReply(const NimFfiMsg& msg) {
        Waiter waiter;
        {
            std::lock_guard<std::mutex> lock(waitMtx_);
            auto it = waiters_.find(msg.id);
            if (it == waiters_.end()) return;
            waiter = std::move(it->second);
            waiters_.erase(it);
        }
        auto result = Result<Bytes>::err("out of memory");
        try {
            if (msg.ret_code == NIMFFI_RET_OK)
                result = Result<Bytes>::ok(Bytes(msg.payload, msg.payload + msg.len));
            else
                result = Result<Bytes>::err(
                    std::string(reinterpret_cast<const char*>(msg.payload), msg.len));
        } catch (...) {
        }
        finish(waiter, std::move(result));
    }

    // So a future never hangs: nobody else watches an async call's deadline.
    void sweepExpired() {
        const auto now = std::chrono::steady_clock::now();
        if (now < nextSweep_) return;
        nextSweep_ = now + std::chrono::milliseconds(SliceMs);
        std::vector<Waiter> expired;
        {
            std::lock_guard<std::mutex> lock(waitMtx_);
            for (auto it = waiters_.begin(); it != waiters_.end();) {
                if (it->second.swept && it->second.deadline <= now) {
                    expired.push_back(std::move(it->second));
                    it = waiters_.erase(it);
                } else {
                    ++it;
                }
            }
        }
        for (auto& waiter : expired)
            finish(waiter, Result<Bytes>::err(timeoutText(waiter.timeout)));
    }

    // Every request still waiting will never be answered.
    void abandon(const std::string& why) {
        std::vector<Waiter> pending;
        {
            std::lock_guard<std::mutex> lock(waitMtx_);
            finished_ = true;
            pending.reserve(waiters_.size());
            for (auto& [id, waiter] : waiters_) pending.push_back(std::move(waiter));
            waiters_.clear();
        }
        for (auto& waiter : pending) finish(waiter, Result<Bytes>::err(why));
    }

    // Copies out under the lock; the handlers then run with the lock released,
    // so a handler may add or remove listeners.
    template <class Fn>
    std::vector<std::shared_ptr<Fn>> matching(std::uint32_t kind, std::uint64_t nameId) {
        std::vector<std::shared_ptr<Fn>> fns;
        std::lock_guard<std::mutex> lock(mtx_);
        for (const auto& [id, l] : listeners_) {
            if (l.kind == kind && l.nameId == nameId)
                fns.push_back(std::static_pointer_cast<Fn>(l.fn));
        }
        return fns;
    }

    template <class Fn, class... Args>
    void call(const std::vector<std::shared_ptr<Fn>>& fns, const Args&... args) {
        for (const auto& fn : fns) {
            if (detached_.load()) return;
            try {
                (*fn)(args...);
            } catch (...) {
                // A listener's exception must not end the dispatch thread.
            }
        }
    }

    // A handler may poll again (a blocking call made inside it), which ends the
    // life of `msg`: whatever a handler is given is copied out first.
    void dispatch(const NimFfiMsg& msg) {
        switch (msg.kind) {
        case NIMFFI_MSG_REPLY:
            deliverReply(msg);
            break;
        case NIMFFI_MSG_EVENT:
            onEvent_(*this, msg);
            break;
        case NIMFFI_MSG_STALE_WARN: {
            const std::uint64_t reqId = msg.id;
            const std::uint64_t elapsedMs = msg.aux;
            call(matching<StaleWarnFn>(NIMFFI_MSG_STALE_WARN, 0), reqId, elapsedMs);
            break;
        }
        case NIMFFI_MSG_NOT_RESPONDING: {
            const std::uint64_t reason = msg.aux;
            call(matching<NotRespondingFn>(NIMFFI_MSG_NOT_RESPONDING, 0), reason);
            break;
        }
        case NIMFFI_MSG_RESPONDING:
            call(matching<RespondingFn>(NIMFFI_MSG_RESPONDING, 0));
            break;
        default:
            break; // a kind from a newer library
        }
    }

    // One poll slice. Dispatch thread only.
    void dispatchOnce(std::int32_t sliceMs) {
        using namespace std::chrono_literals;
        const NimFfiMsg* msg = nullptr;
        const int rc = poll_(ctx_, sliceMs, &msg);
        if (rc == NIMFFI_RET_OK && msg) {
            dispatch(*msg);
        } else if (rc == NIMFFI_RET_CLOSED || rc == NIMFFI_RET_INVALID_CTX) {
            // INVALID_CTX: the context ended between two polls.
            if (rc == NIMFFI_RET_CLOSED && msg && msg->ret_code != NIMFFI_RET_OK) {
                closedOk_ = false;
                if (msg->payload && msg->len > 0)
                    closedReason_.assign(reinterpret_cast<const char*>(msg->payload), msg->len);
            }
            closed_ = true;
            abandon(ClosedText);
            return;
        } else if (rc != NIMFFI_RET_TIMEOUT) {
            std::this_thread::sleep_for(10ms); // BUSY or ERR: try again
        }
        sweepExpired();
    }

    // Ends by failing the waiters, then with the closed notification, whatever
    // stopped it: a closed listener runs exactly once (never after a detach).
    void run() {
        current() = this;
        while (!stop_.load() && !closed_) dispatchOnce(SliceMs);
        abandon(ClosedText);
        call(matching<ClosedFn>(NIMFFI_MSG_CLOSED, 0), closedOk_, closedReason_);
        current() = nullptr;
    }

    const PollFn poll_;
    const LastErrorFn lastError_;
    void* const ctx_;
    const EventFn onEvent_;

    std::mutex mtx_;
    std::map<std::uint64_t, Listener> listeners_; // ordered: handlers run in the order they were added
    std::uint64_t nextId_{1};

    std::mutex waitMtx_;
    std::unordered_map<std::uint64_t, Waiter> waiters_;
    bool finished_{false};

    std::mutex threadMtx_;
    std::thread thread_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> detached_{false};

    // Dispatch thread only.
    bool closed_{false};
    bool closedOk_{true};
    std::string closedReason_;
    std::chrono::steady_clock::time_point nextSweep_{};
};

// The dispatch thread of a library's static context, where `{.ffiStatic.}` replies arrive.
// One per library and process, started by the first static call. Never
// destroyed: the thread may still be polling while the process exits.
class NimFfiStaticDispatcher {
public:
    using StaticCtxFn = void* (*)();

    // The running dispatch thread; a new one when there is none or the static context is
    // another one by now (the library was shut down in between).
    Result<std::shared_ptr<NimFfiDispatcher>> acquire(StaticCtxFn staticCtx, NimFfiDispatcher::PollFn poll,
                                                NimFfiDispatcher::LastErrorFn lastError) {
        using Ret = Result<std::shared_ptr<NimFfiDispatcher>>;
        std::lock_guard<std::mutex> lock(mtx_);
        void* token = staticCtx();
        if (!token) return Ret::err(NimFfiDispatcher::refusal(lastError, NIMFFI_RET_ERR));
        if (dispatcher_ && token == token_ && !dispatcher_->finished()) return Ret::ok(dispatcher_);
        stopLocked();
        auto dispatcher = std::make_shared<NimFfiDispatcher>(poll, lastError, token, &noEvents);
        if (!dispatcher->start()) return Ret::err("could not start the dispatch thread");
        dispatcher_ = dispatcher;
        token_ = token;
        return Ret::ok(std::move(dispatcher));
    }

    // Fails the static calls still waiting and joins the thread, which takes up
    // to one poll slice.
    void stop() {
        std::lock_guard<std::mutex> lock(mtx_);
        stopLocked();
    }

private:
    static void noEvents(NimFfiDispatcher&, const NimFfiMsg&) {}

    void stopLocked() {
        if (!dispatcher_) return;
        dispatcher_->stop();
        dispatcher_.reset();
        token_ = nullptr;
    }

    std::mutex mtx_;
    std::shared_ptr<NimFfiDispatcher> dispatcher_;
    void* token_{nullptr};
};

#endif // NIM_FFI_DISPATCHER_HPP_INCLUDED

// ============================================================
// High-level C++ context class
// ============================================================

class EchoCtx {
public:
    /// Creates an echo context that prefixes every reply with `config.prefix`.
    static Result<std::unique_ptr<EchoCtx>> create(const EchoConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        using Ret = Result<std::unique_ptr<EchoCtx>>;
        const auto ffi_req_ = EchoCreateCtorReq{config};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Ret::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        void* ffi_ptr_ = nullptr;
        std::uint64_t ffi_id_ = 0;
        const int ffi_rc_ = echo_create(ffi_req_bytes_.data(), ffi_req_bytes_.size(), &ffi_ptr_, &ffi_id_);
        if (ffi_rc_ != NIMFFI_RET_OK)
            return Ret::err(NimFfiDispatcher::refusal(&echo_last_error, ffi_rc_));
        // `new` (not make_unique) so the constructor can stay private.
        auto ffi_ctx_ = std::unique_ptr<EchoCtx>(new EchoCtx(ffi_ptr_, timeout));
        // Whether the construction worked is a reply on the new context. A failed
        // one still claimed it: the destructor of `ffi_ctx_` releases it.
        auto ffi_raw_ = ffi_ctx_->dispatcher_->startAndWait(ffi_id_, timeout);
        if (ffi_raw_.isErr()) return Ret::err(ffi_raw_.error());
        return Ret::ok(std::move(ffi_ctx_));
    }

    /// Creates an echo context that prefixes every reply with `config.prefix`.
    static std::future<Result<std::unique_ptr<EchoCtx>>> createAsync(const EchoConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        using Ret = Result<std::unique_ptr<EchoCtx>>;
        const auto ffi_req_ = EchoCreateCtorReq{config};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return NimFfiDispatcher::ready(Ret::err(ffi_enc_.error()));
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        void* ffi_ptr_ = nullptr;
        std::uint64_t ffi_id_ = 0;
        const int ffi_rc_ = echo_create(ffi_req_bytes_.data(), ffi_req_bytes_.size(), &ffi_ptr_, &ffi_id_);
        if (ffi_rc_ != NIMFFI_RET_OK)
            return NimFfiDispatcher::ready(Ret::err(NimFfiDispatcher::refusal(&echo_last_error, ffi_rc_)));
        auto ffi_promise_ = std::make_shared<std::promise<Ret>>();
        auto ffi_future_ = ffi_promise_->get_future();
        // The completion owns the context until the reply says it was built
        // (shared: a std::function must be copyable).
        auto ffi_held_ = std::make_shared<std::unique_ptr<EchoCtx>>(new EchoCtx(ffi_ptr_, timeout));
        auto ffi_dispatcher_ = (*ffi_held_)->dispatcher_;
        ffi_dispatcher_->startAndThen(ffi_id_, timeout,
            [ffi_held_, ffi_promise_](Result<NimFfiDispatcher::Bytes> ffi_raw_) {
                auto ffi_ctx_ = std::move(*ffi_held_);
                if (ffi_raw_.isErr()) {
                    ffi_ctx_.reset(); // a failed construction still claimed the context
                    ffi_promise_->set_value(Ret::err(ffi_raw_.error()));
                } else {
                    ffi_promise_->set_value(Ret::ok(std::move(ffi_ctx_)));
                }
            });
        return ffi_future_;
    }

    // Special-member policy: this class owns a echo context, which in
    // turn owns the library's worker thread(s) and internal state. Moving
    // such an object out from under a caller silently tears that state
    // down and is easy to misuse (e.g. storing in a container that
    // relocates its elements). It also has no clean analogue in the other
    // binding languages we generate. So copies and moves are both
    // deleted; ownership is transferred via EchoCtx::create returning a
    // std::unique_ptr<EchoCtx>. The destructor still releases the
    // context.
    ~EchoCtx() {
        if (ptr_) {
            // Before the dispatch loop stops: the teardown may still emit events, and the
            // poll the dispatch thread is blocked in wakes with NIMFFI_RET_CLOSED.
            echo_destroy(ptr_);
            ptr_ = nullptr;
        }
        // A listener may destroy its own context: that runs on the dispatch thread,
        // which cannot join itself and owns its own reference to `dispatcher_`.
        dispatcher_->stop();
    }

    EchoCtx(const EchoCtx&) = delete;
    EchoCtx& operator=(const EchoCtx&) = delete;
    EchoCtx(EchoCtx&&) = delete;
    EchoCtx& operator=(EchoCtx&&) = delete;

    // ── Messages from the library ───────────────────────────
    // Everything echo sends comes out of echo_poll on this context's dispatch thread:
    //   NIMFFI_MSG_REPLY           -> the method that made the request
    //   NIMFFI_MSG_STALE_WARN      -> addStaleWarnListener
    //   NIMFFI_MSG_NOT_RESPONDING  -> addNotRespondingListener
    //   NIMFFI_MSG_RESPONDING      -> addRespondingListener
    //   NIMFFI_MSG_CLOSED          -> addClosedListener
    // Listeners run on the dispatch thread, in the order they were added. One may add
    // or remove listeners, destroy the context, or make a blocking call on this
    // context: the call then polls in place, so other listeners can run before it
    // returns. It must never wait on a future of this context (`xAsync().get()`):
    // only the dispatch thread, which it is blocking, can fulfil that future.
    struct ListenerHandle { std::uint64_t id = 0; };

    /// Request `reqId` is still running after `elapsedMs`; its reply still comes.
    ListenerHandle addStaleWarnListener(std::function<void(std::uint64_t reqId, std::uint64_t elapsedMs)> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_STALE_WARN, 0, std::move(handler))};
    }

    /// The context stopped answering. `reason` is NIMFFI_NOT_RESPONDING_HEARTBEAT
    /// (the FFI thread's heartbeat stalled) or NIMFFI_NOT_RESPONDING_EVENT_QUEUE_FULL
    /// (the event queue overflowed; requests are refused until the context is recycled).
    ListenerHandle addNotRespondingListener(std::function<void(std::uint64_t reason)> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_NOT_RESPONDING, 0, std::move(handler))};
    }

    /// The FFI thread's heartbeat resumed after a NIMFFI_NOT_RESPONDING_HEARTBEAT.
    ListenerHandle addRespondingListener(std::function<void()> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_RESPONDING, 0, std::move(handler))};
    }

    /// The context is gone: the last call any listener of this context receives,
    /// exactly once. Every call still waiting for its reply has failed by then.
    /// `ok` is false when the library gave the context up, and `reason` then says
    /// why. Not called when a listener destroys the context from the dispatch thread.
    ListenerHandle addClosedListener(std::function<void(bool ok, const std::string& reason)> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_CLOSED, 0, std::move(handler))};
    }

    /// Unregister any listener added above. False when the handle is unknown.
    /// Safe from any thread, a listener included. A delivery already in flight
    /// may still reach the removed listener once, so keep what it captures alive
    /// until then.
    bool removeEventListener(ListenerHandle handle) {
        if (handle.id == 0) return false;
        return dispatcher_->remove(handle.id);
    }

    /// Upper-cases `req.text` and returns it behind the context's prefix.
    Result<ShoutResponse> shout(const ShoutRequest& req) const {
        const auto ffi_req_ = EchoShoutReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<ShoutResponse>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        return dispatcher_->call<ShoutResponse>([&](std::uint64_t* ffi_id_) {
            return echo_shout(ptr_, ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);
        }, timeout_);
    }

    /// Upper-cases `req.text` and returns it behind the context's prefix.
    std::future<Result<ShoutResponse>> shoutAsync(const ShoutRequest& req) const {
        const auto ffi_req_ = EchoShoutReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return NimFfiDispatcher::ready(Result<ShoutResponse>::err(ffi_enc_.error()));
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        return dispatcher_->callAsync<ShoutResponse>([&](std::uint64_t* ffi_id_) {
            return echo_shout(ptr_, ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);
        }, timeout_);
    }

    /// Returns the library's version string.
    Result<std::string> version() const {
        const auto ffi_req_ = EchoVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<std::string>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        return dispatcher_->call<std::string>([&](std::uint64_t* ffi_id_) {
            return echo_version(ptr_, ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);
        }, timeout_);
    }

    /// Returns the library's version string.
    std::future<Result<std::string>> versionAsync() const {
        const auto ffi_req_ = EchoVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return NimFfiDispatcher::ready(Result<std::string>::err(ffi_enc_.error()));
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        return dispatcher_->callAsync<std::string>([&](std::uint64_t* ffi_id_) {
            return echo_version(ptr_, ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);
        }, timeout_);
    }

    static Result<std::string> lib_version(std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoLibVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<std::string>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_dispatcher_ = staticDispatcher_();
        if (ffi_dispatcher_.isErr()) return Result<std::string>::err(ffi_dispatcher_.error());
        return ffi_dispatcher_.value()->call<std::string>([&](std::uint64_t* ffi_id_) {
            return echo_lib_version(ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);
        }, timeout);
    }

    static std::future<Result<std::string>> lib_versionAsync(std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoLibVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return NimFfiDispatcher::ready(Result<std::string>::err(ffi_enc_.error()));
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_dispatcher_ = staticDispatcher_();
        if (ffi_dispatcher_.isErr()) return NimFfiDispatcher::ready(Result<std::string>::err(ffi_dispatcher_.error()));
        return ffi_dispatcher_.value()->callAsync<std::string>([&](std::uint64_t* ffi_id_) {
            return echo_lib_version(ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);
        }, timeout);
    }

    static Result<ShoutResponse> shout_anon(const ShoutRequest& req, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoShoutAnonReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<ShoutResponse>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_dispatcher_ = staticDispatcher_();
        if (ffi_dispatcher_.isErr()) return Result<ShoutResponse>::err(ffi_dispatcher_.error());
        return ffi_dispatcher_.value()->call<ShoutResponse>([&](std::uint64_t* ffi_id_) {
            return echo_shout_anon(ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);
        }, timeout);
    }

    static std::future<Result<ShoutResponse>> shout_anonAsync(const ShoutRequest& req, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoShoutAnonReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return NimFfiDispatcher::ready(Result<ShoutResponse>::err(ffi_enc_.error()));
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_dispatcher_ = staticDispatcher_();
        if (ffi_dispatcher_.isErr()) return NimFfiDispatcher::ready(Result<ShoutResponse>::err(ffi_dispatcher_.error()));
        return ffi_dispatcher_.value()->callAsync<ShoutResponse>([&](std::uint64_t* ffi_id_) {
            return echo_shout_anon(ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);
        }, timeout);
    }

    /// Stop every context the library still holds and join their threads.
    /// Call it before the process exits when a context is still alive, or when a
    /// static proc built the shared context.
    /// Returns 0 when every context stopped, 1 when one was left running.
    /// Static calls still waiting fail with a "context closed" error, and a
    /// later static call starts over. Must not race a call in flight.
    static Result<void> shutdown() {
        // The static dispatch thread goes first: nothing polls a context being torn down.
        staticDispatcherHolder_().stop();
        if (echo_shutdown() != 0) return Result<void>::err("echo_shutdown: a context was left running");
        return Result<void>::ok();
    }

private:
    static void dispatchEvent_(NimFfiDispatcher&, const NimFfiMsg&) {}

    // `{.ffiStatic.}` replies arrive on the library's static context, which has
    // one dispatch thread per process, started by the first static call.
    static Result<std::shared_ptr<NimFfiDispatcher>> staticDispatcher_() {
        return staticDispatcherHolder_().acquire(&echo_static_ctx, &echo_poll, &echo_last_error);
    }
    // Never destroyed: no static destructor may race the dispatch thread at exit.
    static NimFfiStaticDispatcher& staticDispatcherHolder_() {
        static NimFfiStaticDispatcher* holder = new NimFfiStaticDispatcher();
        return *holder;
    }

    void* ptr_;
    std::chrono::milliseconds timeout_;
    std::shared_ptr<NimFfiDispatcher> dispatcher_;
    explicit EchoCtx(void* p, std::chrono::milliseconds t)
        : ptr_(p), timeout_(t),
          dispatcher_(std::make_shared<NimFfiDispatcher>(&echo_poll, &echo_last_error, p, &EchoCtx::dispatchEvent_)) {}
};
