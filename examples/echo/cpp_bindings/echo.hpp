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
#include <chrono>
#include <charconv>
#include <mutex>
#include <condition_variable>
#include <memory>
#include <functional>
#include <future>
#include <vector>
#include <map>
#include <optional>
#include <type_traits>
#include <cstring>
#include <exception>
#include <cassert>
#include <limits>
#include <thread>
extern "C" {
#include <tinycbor/cbor.h>
}

// nim-ffi result-callback status codes (mirror ffi/ffi_types.nim and the C
// header). Guarded so a translation unit that also pulls in the C header keeps
// a single definition.
#ifndef NIMFFI_RET_OK
#define NIMFFI_RET_OK 0
#define NIMFFI_RET_ERR 1
#define NIMFFI_RET_MISSING_CALLBACK 2
#define NIMFFI_RET_STALE_WARN 3
#define NIMFFI_RET_TIMEOUT 4
#define NIMFFI_RET_CLOSED 5
#define NIMFFI_RET_INVALID_CTX 6
#define NIMFFI_RET_BUSY 7
#define NIMFFI_RET_QUEUE_FULL 8
#define NIMFFI_RET_TOO_LARGE 9
#define NIMFFI_RET_NOT_ACTIVE 10
#define NIMFFI_RET_WORKERS_FAILED 11
#define NIMFFI_RET_INVALID_ARGUMENT 12
#define NIMFFI_RET_OUT_OF_MEMORY 13
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
inline CborError encode_cbor(CborEncoder& e, int16_t v) {
    return cbor_encode_int(&e, static_cast<int64_t>(v));
}
inline CborError encode_cbor(CborEncoder& e, int8_t v) {
    return cbor_encode_int(&e, static_cast<int64_t>(v));
}
inline CborError encode_cbor(CborEncoder& e, uint64_t v) {
    return cbor_encode_uint(&e, v);
}
// Every width the codegen emits needs its own overload: without one, a
// uint32_t/uint16_t/uint8_t argument converts equally well to bool, int32_t,
// int64_t and uint64_t, and the call is ambiguous.
inline CborError encode_cbor(CborEncoder& e, uint32_t v) {
    return cbor_encode_uint(&e, static_cast<uint64_t>(v));
}
inline CborError encode_cbor(CborEncoder& e, uint16_t v) {
    return cbor_encode_uint(&e, static_cast<uint64_t>(v));
}
inline CborError encode_cbor(CborEncoder& e, uint8_t v) {
    return cbor_encode_uint(&e, static_cast<uint64_t>(v));
}
inline CborError encode_cbor(CborEncoder& e, double v) {
    return cbor_encode_double(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, float v) {
    return cbor_encode_float(&e, v);
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

// Narrow integers decode through the 64-bit readers and refuse a value that
// does not fit, rather than truncating it.
template<typename Narrow, typename Wide>
inline CborError decode_narrow_cbor(CborValue& it, Narrow& out) {
    Wide tmp = 0;
    CborError err = decode_cbor(it, tmp);
    if (err) return err;
    if (tmp < static_cast<Wide>(std::numeric_limits<Narrow>::min()) ||
        tmp > static_cast<Wide>(std::numeric_limits<Narrow>::max())) {
        return CborErrorDataTooLarge;
    }
    out = static_cast<Narrow>(tmp);
    return CborNoError;
}
inline CborError decode_cbor(CborValue& it, int16_t& out) {
    return decode_narrow_cbor<int16_t, int64_t>(it, out);
}
inline CborError decode_cbor(CborValue& it, int8_t& out) {
    return decode_narrow_cbor<int8_t, int64_t>(it, out);
}
inline CborError decode_cbor(CborValue& it, uint32_t& out) {
    return decode_narrow_cbor<uint32_t, uint64_t>(it, out);
}
inline CborError decode_cbor(CborValue& it, uint16_t& out) {
    return decode_narrow_cbor<uint16_t, uint64_t>(it, out);
}
inline CborError decode_cbor(CborValue& it, uint8_t& out) {
    return decode_narrow_cbor<uint8_t, uint64_t>(it, out);
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
inline CborError decode_cbor(CborValue& it, float& out) {
    double tmp = 0.0;
    CborError err = decode_cbor(it, tmp);
    if (err) return err;
    out = static_cast<float>(tmp);
    return CborNoError;
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
// C FFI declarations
// ============================================================

extern "C" {
typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);

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
} // extern "C"

// ============================================================
// Call helpers
// ============================================================
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED
#define NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED

// Gets the elapsed time on each RET_STALE_WARN. Runs on a library thread, also after a timeout.
using FFIProgress = std::function<void(std::chrono::milliseconds)>;

namespace {

using FFIBytes_ = std::vector<std::uint8_t>;

// The first of the terminal callback, a timeout and a failed submit settles the call.
template <typename T>
struct FFICallState_ {
    std::mutex                    mtx;
    bool                          settled{false};
    std::promise<Result<T>>       promise;
    FFIProgress                   progress;
    std::function<Result<T>(FFIBytes_&&)> decode;
    std::function<void()>         onSettled;

    bool live() {
        std::lock_guard<std::mutex> lock(mtx);
        return !settled;
    }

    void settle(Result<T> r) {
        std::function<void()> done;
        {
            std::lock_guard<std::mutex> lock(mtx);
            if (settled) return;
            settled = true;
            done = std::move(onSettled);
        }
        promise.set_value(std::move(r));
        if (done) done();
    }
};

// Runs deadlines for async calls on one shared thread, so no call owns a thread.
class FFITimer_ {
    using Clock = std::chrono::steady_clock;
    std::mutex mtx_;
    std::condition_variable cv_;
    std::map<std::pair<Clock::time_point, std::uint64_t>, std::function<void()>> q_;
    std::uint64_t next_{0};

    FFITimer_() { std::thread([this] { run_(); }).detach(); }

    // Never returns: the thread runs until the process exits.
    void run_() {
        std::unique_lock<std::mutex> lock(mtx_);
        for (;;) {
            if (q_.empty()) { cv_.wait(lock); continue; }
            const auto first = q_.begin();
            const auto due = first->first.first;
            if (due > Clock::now()) {
                cv_.wait_until(lock, due);
                continue;
            }
            auto fn = std::move(first->second);
            q_.erase(first);
            lock.unlock();
            fn();
            lock.lock();
        }
    }

public:
    // Never destroyed: the thread outlives static destruction.
    static FFITimer_& get() {
        static FFITimer_* t = new FFITimer_();
        return *t;
    }

    std::uint64_t at(std::chrono::milliseconds after, std::function<void()> fn) {
        std::lock_guard<std::mutex> lock(mtx_);
        const auto id = next_++;
        q_.emplace(std::make_pair(Clock::now() + after, id), std::move(fn));
        cv_.notify_one();
        return id;
    }

    void cancel(std::uint64_t id) {
        std::lock_guard<std::mutex> lock(mtx_);
        for (auto it = q_.begin(); it != q_.end(); ++it) {
            if (it->first.second == id) { q_.erase(it); return; }
        }
    }
};

template <typename T>
inline void ffi_cb_(int ret, const char* msg, size_t len, void* ud) {
    using State = FFICallState_<T>;
    // Non-terminal ping: leave `ud` alone, the terminal callback still owns the handle.
    if (ret == NIMFFI_RET_STALE_WARN) {
        State& s = **static_cast<std::shared_ptr<State>*>(ud);
        if (!s.progress) return;
        long long ms = 0;
        if (msg && len > 0) std::from_chars(msg, msg + len, ms);
        // An exception must not unwind into the library thread.
        try { s.progress(std::chrono::milliseconds{ms}); } catch (...) {}
        return;
    }

    std::unique_ptr<std::shared_ptr<State>> handle(
        static_cast<std::shared_ptr<State>*>(ud));
    State& s = **handle;
    if (!s.live()) return;

    if (ret != NIMFFI_RET_OK) {
        s.settle(Result<T>::err(msg && len > 0 ? std::string(msg, len) : std::string{}));
        return;
    }

    const auto* p = reinterpret_cast<const std::uint8_t*>(msg);
    FFIBytes_ bytes;
    if (msg && len > 0) bytes.assign(p, p + len);
    s.settle([&]() -> Result<T> {
        try { return s.decode(std::move(bytes)); }
        catch (...) { return Result<T>::err("reply decode threw"); }
    }());
}

template <typename T>
inline std::pair<std::shared_ptr<FFICallState_<T>>, std::future<Result<T>>>
ffi_submit_(const std::function<int(FFICallback, void*)>& f,
            FFIProgress progress,
            std::function<Result<T>(FFIBytes_&&)> decode) {
    auto state = std::make_shared<FFICallState_<T>>();
    state->progress = std::move(progress);
    state->decode = std::move(decode);
    auto fut = state->promise.get_future();
    auto* cb_ref = new std::shared_ptr<FFICallState_<T>>(state);
    const int ret = f(&ffi_cb_<T>, cb_ref);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        delete cb_ref;
        state->settle(Result<T>::err("RET_MISSING_CALLBACK (internal error)"));
    }
    return {std::move(state), std::move(fut)};
}

inline std::string ffi_timeout_msg_(std::chrono::milliseconds limit) {
    return "FFI call timed out after " + std::to_string(limit.count()) + "ms";
}

// A nullopt `timeout` waits with no limit. A timeout only stops the wait.
inline Result<FFIBytes_> ffi_call_(
        std::function<int(FFICallback, void*)> f,
        std::optional<std::chrono::milliseconds> timeout,
        FFIProgress progress = {}) {
    auto [state, fut] = ffi_submit_<FFIBytes_>(
        f, std::move(progress),
        [](FFIBytes_&& b) { return Result<FFIBytes_>::ok(std::move(b)); });
    if (timeout && fut.wait_for(*timeout) != std::future_status::ready)
        state->settle(Result<FFIBytes_>::err(ffi_timeout_msg_(*timeout)));
    return fut.get();
}

// Like ffi_call_, but returns at once; `f` runs before this returns.
template <typename T>
inline std::future<Result<T>> ffi_call_async_(
        std::function<int(FFICallback, void*)> f,
        std::optional<std::chrono::milliseconds> timeout,
        FFIProgress progress,
        std::function<Result<T>(FFIBytes_&&)> decode) {
    auto [state, fut] = ffi_submit_<T>(f, std::move(progress), std::move(decode));
    if (!timeout || !state->live()) return std::move(fut);

    const auto limit = *timeout;
    const auto id = FFITimer_::get().at(limit, [w = std::weak_ptr<FFICallState_<T>>(state), limit] {
        if (auto s = w.lock()) s->settle(Result<T>::err(ffi_timeout_msg_(limit)));
    });
    {
        std::lock_guard<std::mutex> lock(state->mtx);
        if (state->settled) FFITimer_::get().cancel(id);
        else state->onSettled = [id] { FFITimer_::get().cancel(id); };
    }
    return std::move(fut);
}

} // anonymous namespace

#endif // NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED

// ============================================================
// High-level C++ context class
// ============================================================

// Instance calls of a EchoCtx with their limit (nullopt: none) and progress callback. Borrows the ctx.
class EchoCalls {
public:
    EchoCalls withTimeout(std::optional<std::chrono::milliseconds> limit) const {
        EchoCalls c(*this);
        c.timeout_ = limit;
        return c;
    }

    EchoCalls withProgress(FFIProgress onProgress) const {
        EchoCalls c(*this);
        c.progress_ = std::move(onProgress);
        return c;
    }

    /// Upper-cases `req.text` and returns it behind the context's prefix.
    Result<ShoutResponse> shout(const ShoutRequest& req) const {
        const auto ffi_req_ = EchoShoutReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<ShoutResponse>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return ::echo_shout(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_, progress_);
        if (ffi_raw_.isErr()) return Result<ShoutResponse>::err(ffi_raw_.error());
        return decodeCborFFI<ShoutResponse>(ffi_raw_.value());
    }

    /// Upper-cases `req.text` and returns it behind the context's prefix.
    std::future<Result<ShoutResponse>> shoutAsync(const ShoutRequest& req) const {
        const auto ffi_req_ = EchoShoutReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) {
            std::promise<Result<ShoutResponse>> ffi_p_;
            ffi_p_.set_value(Result<ShoutResponse>::err(ffi_enc_.error()));
            return ffi_p_.get_future();
        }
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        return ffi_call_async_<ShoutResponse>([&](FFICallback cb, void* ud) {
            return ::echo_shout(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_, progress_, [](FFIBytes_&& b) { return decodeCborFFI<ShoutResponse>(b); });
    }

    /// Returns the library's version string.
    Result<std::string> version() const {
        const auto ffi_req_ = EchoVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<std::string>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return ::echo_version(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_, progress_);
        if (ffi_raw_.isErr()) return Result<std::string>::err(ffi_raw_.error());
        return decodeCborFFI<std::string>(ffi_raw_.value());
    }

    /// Returns the library's version string.
    std::future<Result<std::string>> versionAsync() const {
        const auto ffi_req_ = EchoVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) {
            std::promise<Result<std::string>> ffi_p_;
            ffi_p_.set_value(Result<std::string>::err(ffi_enc_.error()));
            return ffi_p_.get_future();
        }
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        return ffi_call_async_<std::string>([&](FFICallback cb, void* ud) {
            return ::echo_version(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_, progress_, [](FFIBytes_&& b) { return decodeCborFFI<std::string>(b); });
    }

protected:
    void* ptr_;
    std::optional<std::chrono::milliseconds> timeout_;
    FFIProgress progress_;
    EchoCalls(void* p, std::optional<std::chrono::milliseconds> t) : ptr_(p), timeout_(t) {}
};

class EchoCtx : public EchoCalls {
public:
    /// Creates an echo context that prefixes every reply with `config.prefix`.
    static Result<std::unique_ptr<EchoCtx>> create(const EchoConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoCreateCtorReq{config};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<std::unique_ptr<EchoCtx>>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        void* ffi_token_ = nullptr;
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            ffi_token_ = ::echo_create(ffi_req_bytes_.data(), ffi_req_bytes_.size(), cb, ud);
            return 0;
        }, timeout);
        if (ffi_raw_.isErr()) {
            if (ffi_token_) std::thread([ffi_token_] { (void)::echo_destroy(ffi_token_); }).detach();
            return Result<std::unique_ptr<EchoCtx>>::err(ffi_raw_.error());
        }
        auto ffi_addr_ = decodeCborFFI<std::string>(ffi_raw_.value());
        if (ffi_addr_.isErr()) return Result<std::unique_ptr<EchoCtx>>::err(ffi_addr_.error());
        const auto& addr_str = ffi_addr_.value();
        std::uint64_t addr = 0;
        const char* addr_begin = addr_str.data();
        const char* addr_end = addr_begin + addr_str.size();
        const auto fc_ = std::from_chars(addr_begin, addr_end, addr);
        if (fc_.ec != std::errc() || fc_.ptr != addr_end) {
            return Result<std::unique_ptr<EchoCtx>>::err("FFI create returned non-numeric address: " + addr_str);
        }
        return Result<std::unique_ptr<EchoCtx>>::ok(std::unique_ptr<EchoCtx>(new EchoCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout)));
    }

    /// Creates an echo context that prefixes every reply with `config.prefix`.
    static std::future<Result<std::unique_ptr<EchoCtx>>> createAsync(const EchoConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        return std::async(std::launch::async, [config, timeout]() { return create(config, timeout); });
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
            echo_destroy(ptr_);
            ptr_ = nullptr;
        }
    }

    EchoCtx(const EchoCtx&) = delete;
    EchoCtx& operator=(const EchoCtx&) = delete;
    EchoCtx(EchoCtx&&) = delete;
    EchoCtx& operator=(EchoCtx&&) = delete;

    static Result<std::string> lib_version(std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoLibVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<std::string>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return ::echo_lib_version(cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout);
        if (ffi_raw_.isErr()) return Result<std::string>::err(ffi_raw_.error());
        return decodeCborFFI<std::string>(ffi_raw_.value());
    }

    static std::future<Result<std::string>> lib_versionAsync(std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoLibVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) {
            std::promise<Result<std::string>> ffi_p_;
            ffi_p_.set_value(Result<std::string>::err(ffi_enc_.error()));
            return ffi_p_.get_future();
        }
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        return ffi_call_async_<std::string>([&](FFICallback cb, void* ud) {
            return ::echo_lib_version(cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout, FFIProgress{}, [](FFIBytes_&& b) { return decodeCborFFI<std::string>(b); });
    }

    static Result<ShoutResponse> shout_anon(const ShoutRequest& req, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoShoutAnonReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<ShoutResponse>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return ::echo_shout_anon(cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout);
        if (ffi_raw_.isErr()) return Result<ShoutResponse>::err(ffi_raw_.error());
        return decodeCborFFI<ShoutResponse>(ffi_raw_.value());
    }

    static std::future<Result<ShoutResponse>> shout_anonAsync(const ShoutRequest& req, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoShoutAnonReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) {
            std::promise<Result<ShoutResponse>> ffi_p_;
            ffi_p_.set_value(Result<ShoutResponse>::err(ffi_enc_.error()));
            return ffi_p_.get_future();
        }
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        return ffi_call_async_<ShoutResponse>([&](FFICallback cb, void* ud) {
            return ::echo_shout_anon(cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout, FFIProgress{}, [](FFIBytes_&& b) { return decodeCborFFI<ShoutResponse>(b); });
    }

private:
    explicit EchoCtx(void* p, std::chrono::milliseconds t) : EchoCalls(p, t) {}
};
