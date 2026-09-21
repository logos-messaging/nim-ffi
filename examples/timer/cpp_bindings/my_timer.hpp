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
#include <atomic>
#include <chrono>
#include <charconv>
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
#include <cstring>
#include <cassert>
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

constexpr int64_t MAX_DELAY_MS = 5000;
constexpr uint32_t DEFAULT_BACKOFF_MS = 250;
constexpr const char* TIMER_VERSION = "nim-timer v0.1.0";

enum class JobPriority {
    jpLow = 0,
    jpNormal = 1,
    jpHigh = 2,
};
inline CborError encode_cbor(CborEncoder& e, const JobPriority& v) {
    switch (v) {
    case JobPriority::jpLow: return cbor_encode_text_stringz(&e, "low");
    case JobPriority::jpNormal: return cbor_encode_text_stringz(&e, "normal");
    case JobPriority::jpHigh: return cbor_encode_text_stringz(&e, "high");
    }
    return CborErrorImproperValue;
}
inline CborError decode_cbor(CborValue& it, JobPriority& v) {
    std::string name;
    CborError err = decode_cbor(it, name);
    if (err) return err;
    if (name == "low") { v = JobPriority::jpLow; return CborNoError; }
    if (name == "normal") { v = JobPriority::jpNormal; return CborNoError; }
    if (name == "high") { v = JobPriority::jpHigh; return CborNoError; }
    return CborErrorImproperValue;
}

// ============================================================
// User-declared FFI types
// ============================================================

struct TimerConfig {
    std::string name;
};
inline CborError encode_cbor(CborEncoder& e, const TimerConfig& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "name"); if (err) return err;
    err = encode_cbor(m, v.name);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, TimerConfig& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "name", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.name); if (err) return err;
    return cbor_value_advance(&it);
}

struct EchoRequest {
    std::string message;
    int64_t delayMs;
};
inline CborError encode_cbor(CborEncoder& e, const EchoRequest& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "message"); if (err) return err;
    err = encode_cbor(m, v.message);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "delayMs"); if (err) return err;
    err = encode_cbor(m, v.delayMs);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoRequest& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "message", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.message); if (err) return err;
    err = cbor_value_map_find_value(&it, "delayMs", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.delayMs); if (err) return err;
    return cbor_value_advance(&it);
}

struct EchoResponse {
    std::string echoed;
    std::string timerName;
};
inline CborError encode_cbor(CborEncoder& e, const EchoResponse& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "echoed"); if (err) return err;
    err = encode_cbor(m, v.echoed);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "timerName"); if (err) return err;
    err = encode_cbor(m, v.timerName);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoResponse& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "echoed", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.echoed); if (err) return err;
    err = cbor_value_map_find_value(&it, "timerName", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.timerName); if (err) return err;
    return cbor_value_advance(&it);
}

struct ComplexRequest {
    std::vector<EchoRequest> messages;
    std::vector<std::string> tags;
    std::optional<std::string> note;
    std::optional<int64_t> retries;
};
inline CborError encode_cbor(CborEncoder& e, const ComplexRequest& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 4);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "messages"); if (err) return err;
    err = encode_cbor(m, v.messages);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "tags"); if (err) return err;
    err = encode_cbor(m, v.tags);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "note"); if (err) return err;
    err = encode_cbor(m, v.note);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "retries"); if (err) return err;
    err = encode_cbor(m, v.retries);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, ComplexRequest& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "messages", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.messages); if (err) return err;
    err = cbor_value_map_find_value(&it, "tags", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.tags); if (err) return err;
    err = cbor_value_map_find_value(&it, "note", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.note); if (err) return err;
    err = cbor_value_map_find_value(&it, "retries", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.retries); if (err) return err;
    return cbor_value_advance(&it);
}

struct ComplexResponse {
    std::string summary;
    int64_t itemCount;
    bool hasNote;
};
inline CborError encode_cbor(CborEncoder& e, const ComplexResponse& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "summary"); if (err) return err;
    err = encode_cbor(m, v.summary);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "itemCount"); if (err) return err;
    err = encode_cbor(m, v.itemCount);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "hasNote"); if (err) return err;
    err = encode_cbor(m, v.hasNote);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, ComplexResponse& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "summary", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.summary); if (err) return err;
    err = cbor_value_map_find_value(&it, "itemCount", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.itemCount); if (err) return err;
    err = cbor_value_map_find_value(&it, "hasNote", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.hasNote); if (err) return err;
    return cbor_value_advance(&it);
}

struct EchoEvent {
    std::string message;
    int64_t echoCount;
};
inline CborError encode_cbor(CborEncoder& e, const EchoEvent& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "message"); if (err) return err;
    err = encode_cbor(m, v.message);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "echoCount"); if (err) return err;
    err = encode_cbor(m, v.echoCount);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoEvent& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "message", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.message); if (err) return err;
    err = cbor_value_map_find_value(&it, "echoCount", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.echoCount); if (err) return err;
    return cbor_value_advance(&it);
}

struct OnJobScheduledPayload {
    std::string jobId;
    int64_t willRunCount;
};
inline CborError encode_cbor(CborEncoder& e, const OnJobScheduledPayload& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "jobId"); if (err) return err;
    err = encode_cbor(m, v.jobId);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "willRunCount"); if (err) return err;
    err = encode_cbor(m, v.willRunCount);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, OnJobScheduledPayload& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "jobId", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.jobId); if (err) return err;
    err = cbor_value_map_find_value(&it, "willRunCount", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.willRunCount); if (err) return err;
    return cbor_value_advance(&it);
}

struct JobSpec {
    std::string name;
    std::vector<std::string> payload;
    JobPriority priority;
};
inline CborError encode_cbor(CborEncoder& e, const JobSpec& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "name"); if (err) return err;
    err = encode_cbor(m, v.name);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "payload"); if (err) return err;
    err = encode_cbor(m, v.payload);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "priority"); if (err) return err;
    err = encode_cbor(m, v.priority);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, JobSpec& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "name", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.name); if (err) return err;
    err = cbor_value_map_find_value(&it, "payload", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.payload); if (err) return err;
    err = cbor_value_map_find_value(&it, "priority", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.priority); if (err) return err;
    return cbor_value_advance(&it);
}

struct RetryPolicy {
    int64_t maxAttempts;
    int64_t backoffMs;
    std::vector<std::string> retryOn;
};
inline CborError encode_cbor(CborEncoder& e, const RetryPolicy& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "maxAttempts"); if (err) return err;
    err = encode_cbor(m, v.maxAttempts);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "backoffMs"); if (err) return err;
    err = encode_cbor(m, v.backoffMs);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "retryOn"); if (err) return err;
    err = encode_cbor(m, v.retryOn);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, RetryPolicy& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "maxAttempts", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.maxAttempts); if (err) return err;
    err = cbor_value_map_find_value(&it, "backoffMs", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.backoffMs); if (err) return err;
    err = cbor_value_map_find_value(&it, "retryOn", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.retryOn); if (err) return err;
    return cbor_value_advance(&it);
}

struct ScheduleConfig {
    int64_t startAtMs;
    int64_t intervalMs;
    std::optional<int64_t> jitter;
};
inline CborError encode_cbor(CborEncoder& e, const ScheduleConfig& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "startAtMs"); if (err) return err;
    err = encode_cbor(m, v.startAtMs);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "intervalMs"); if (err) return err;
    err = encode_cbor(m, v.intervalMs);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "jitter"); if (err) return err;
    err = encode_cbor(m, v.jitter);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, ScheduleConfig& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "startAtMs", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.startAtMs); if (err) return err;
    err = cbor_value_map_find_value(&it, "intervalMs", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.intervalMs); if (err) return err;
    err = cbor_value_map_find_value(&it, "jitter", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.jitter); if (err) return err;
    return cbor_value_advance(&it);
}

struct ScheduleResult {
    std::string jobId;
    int64_t willRunCount;
    int64_t firstRunAtMs;
    int64_t effectiveBackoffMs;
    JobPriority priority;
};
inline CborError encode_cbor(CborEncoder& e, const ScheduleResult& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 5);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "jobId"); if (err) return err;
    err = encode_cbor(m, v.jobId);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "willRunCount"); if (err) return err;
    err = encode_cbor(m, v.willRunCount);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "firstRunAtMs"); if (err) return err;
    err = encode_cbor(m, v.firstRunAtMs);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "effectiveBackoffMs"); if (err) return err;
    err = encode_cbor(m, v.effectiveBackoffMs);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "priority"); if (err) return err;
    err = encode_cbor(m, v.priority);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, ScheduleResult& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "jobId", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.jobId); if (err) return err;
    err = cbor_value_map_find_value(&it, "willRunCount", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.willRunCount); if (err) return err;
    err = cbor_value_map_find_value(&it, "firstRunAtMs", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.firstRunAtMs); if (err) return err;
    err = cbor_value_map_find_value(&it, "effectiveBackoffMs", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.effectiveBackoffMs); if (err) return err;
    err = cbor_value_map_find_value(&it, "priority", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.priority); if (err) return err;
    return cbor_value_advance(&it);
}

// ============================================================
// Per-proc request envelopes (CBOR encoded on the wire)
// ============================================================

struct MyTimerCreateCtorReq {
    TimerConfig config;
};
inline CborError encode_cbor(CborEncoder& e, const MyTimerCreateCtorReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "config"); if (err) return err;
    err = encode_cbor(m, v.config);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, MyTimerCreateCtorReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "config", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.config); if (err) return err;
    return cbor_value_advance(&it);
}

struct MyTimerEchoReq {
    EchoRequest req;
};
inline CborError encode_cbor(CborEncoder& e, const MyTimerEchoReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req"); if (err) return err;
    err = encode_cbor(m, v.req);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, MyTimerEchoReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "req", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.req); if (err) return err;
    return cbor_value_advance(&it);
}

struct MyTimerVersionReq {
};
inline CborError encode_cbor(CborEncoder& e, const MyTimerVersionReq&) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, MyTimerVersionReq&) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    return cbor_value_advance(&it);
}

struct MyTimerLibVersionReq {
};
inline CborError encode_cbor(CborEncoder& e, const MyTimerLibVersionReq&) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, MyTimerLibVersionReq&) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    return cbor_value_advance(&it);
}

struct MyTimerComplexReq {
    ComplexRequest req;
};
inline CborError encode_cbor(CborEncoder& e, const MyTimerComplexReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req"); if (err) return err;
    err = encode_cbor(m, v.req);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, MyTimerComplexReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "req", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.req); if (err) return err;
    return cbor_value_advance(&it);
}

struct MyTimerScheduleReq {
    JobSpec job;
    RetryPolicy retry;
    ScheduleConfig schedule;
};
inline CborError encode_cbor(CborEncoder& e, const MyTimerScheduleReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "job"); if (err) return err;
    err = encode_cbor(m, v.job);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "retry"); if (err) return err;
    err = encode_cbor(m, v.retry);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "schedule"); if (err) return err;
    err = encode_cbor(m, v.schedule);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, MyTimerScheduleReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "job", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.job); if (err) return err;
    err = cbor_value_map_find_value(&it, "retry", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.retry); if (err) return err;
    err = cbor_value_map_find_value(&it, "schedule", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.schedule); if (err) return err;
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
  uint64_t id;
  uint64_t name_id;       /* EVENT: which one. Otherwise 0 */
  uint64_t aux;
  int32_t  ret_code;
  uint32_t flags;
  const uint8_t* payload; /* bare CBOR value; never NULL */
  size_t   len;
} NimFfiMsg;

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
typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);

/** Creates the FFIContext + MyTimer; async via chronos. */
void* my_timer_create(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);
/** Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`. */
int my_timer_echo(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
/** Returns the library's version string. */
int my_timer_version(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_lib_version(FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_complex(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
/** Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope. */
int my_timer_schedule(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
/** Tears down the FFI context; blocks until FFI + watchdog threads join. */
int my_timer_destroy(void* ctx);
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
int my_timer_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);
/**
 * A handle that is ready while a message waits or `ctx` is closed: an epoll fd
 * on Linux, a kqueue fd on macOS/BSD, an Event HANDLE on Windows, -1 on failure.
 * The caller owns it and closes it. Wait on it, then poll with a timeout of 0
 * until NIMFFI_RET_TIMEOUT.
 */
intptr_t my_timer_poll_fd(void* ctx);
/**
 * Stop every context the library still holds and join their threads.
 * Call it before the process exits when a context is still alive, or when a
 * static proc built the shared context.
 * Returns 0 when every context stopped, 1 when one was left running.
 */
int my_timer_shutdown(void);
} // extern "C"

// ============================================================
// Synchronous call helper
// ============================================================
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED
#define NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED

namespace {

struct FFICallState_ {
    std::mutex              mtx;
    std::condition_variable cv;
    bool                    done{false};
    bool                    ok{false};
    std::vector<std::uint8_t> bytes;
    std::string             err;
};

inline void ffi_cb_(int ret, const char* msg, size_t len, void* ud) {
    // NIMFFI_RET_STALE_WARN (3) is a non-terminal progress ping: the request is
    // still running. This blocking wrapper only reports the final result, so
    // ignore it WITHOUT touching `ud` — a terminal callback still owns the
    // shared handle and will free it.
    if (ret == NIMFFI_RET_STALE_WARN) return;

    // ffi_call_ heap-allocated a shared_ptr and passed its address as ud;
    // take ownership here so it's freed on every exit path.
    std::unique_ptr<std::shared_ptr<FFICallState_>> handle(
        static_cast<std::shared_ptr<FFICallState_>*>(ud));
    FFICallState_& s = **handle;

    std::lock_guard<std::mutex> lock(s.mtx);
    s.ok = (ret == NIMFFI_RET_OK);
    if (msg && len > 0) {
        const auto* p = reinterpret_cast<const std::uint8_t*>(msg);
        if (s.ok) s.bytes.assign(p, p + len);
        else      s.err.assign(msg, len);
    }
    s.done = true;
    s.cv.notify_one();
}

inline Result<std::vector<std::uint8_t>> ffi_call_(
        std::function<int(FFICallback, void*)> f,
        std::chrono::milliseconds timeout) {
    using Bytes = std::vector<std::uint8_t>;
    auto state = std::make_shared<FFICallState_>();
    auto* cb_ref = new std::shared_ptr<FFICallState_>(state);
    const int ret = f(ffi_cb_, cb_ref);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        delete cb_ref;
        return Result<Bytes>::err("RET_MISSING_CALLBACK (internal error)");
    }
    std::unique_lock<std::mutex> lock(state->mtx);
    const bool fired = state->cv.wait_for(lock, timeout, [&]{ return state->done; });
    if (!fired)
        return Result<Bytes>::err("FFI call timed out after " +
                                  std::to_string(timeout.count()) + "ms");
    if (!state->ok)
        return Result<Bytes>::err(state->err);
    return Result<Bytes>::ok(std::move(state->bytes));
}

} // anonymous namespace

#endif // NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED

// ============================================================
// Message dispatch
// ============================================================
// The library never calls into the host for an event. Each context owns one
// dispatch thread that takes the messages out through `<lib>_poll` and calls the
// listeners registered on it.
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_DISPATCHER_HPP_INCLUDED
#define NIM_FFI_DISPATCHER_HPP_INCLUDED

class NimFfiDispatcher {
public:
    using PollFn = int (*)(void* ctx, std::int32_t timeout_ms, const NimFfiMsg** msg);
    // Decodes one NIMFFI_MSG_EVENT and delivers it; generated per library.
    using EventFn = void (*)(NimFfiDispatcher& dispatcher, const NimFfiMsg& msg);

    using NotRespondingFn = std::function<void(std::uint64_t reason)>;
    using RespondingFn = std::function<void()>;
    using ClosedFn = std::function<void(bool ok, const std::string& reason)>;

    // Returns a non-joinable thread when the thread could not be started.
    static std::thread start(std::shared_ptr<NimFfiDispatcher> self, PollFn poll,
                             void* ctx, EventFn onEvent) noexcept {
        try {
            return std::thread([self = std::move(self), poll, ctx, onEvent] {
                self->run(poll, ctx, onEvent);
            });
        } catch (...) {
            return std::thread();
        }
    }

    // `detached`: the owner is going away on the dispatch thread itself, so no
    // listener may run once the handler in flight returns.
    void stop(bool detached) {
        if (detached) detached_.store(true);
        stop_.store(true);
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
    // the library and a handler may end the context.
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
    struct Listener {
        std::uint32_t kind;
        std::uint64_t nameId;
        std::shared_ptr<void> fn; // the std::function type that `kind`/`nameId` imply
    };

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

    void dispatch(const NimFfiMsg& msg, EventFn onEvent) {
        switch (msg.kind) {
        case NIMFFI_MSG_EVENT:
            onEvent(*this, msg);
            break;
        case NIMFFI_MSG_NOT_RESPONDING:
            call(matching<NotRespondingFn>(NIMFFI_MSG_NOT_RESPONDING, 0), msg.aux);
            break;
        case NIMFFI_MSG_RESPONDING:
            call(matching<RespondingFn>(NIMFFI_MSG_RESPONDING, 0));
            break;
        default:
            break; // a kind from a newer library
        }
    }

    // Ends with the closed notification whatever stopped it, so a closed
    // listener runs exactly once (never after a `stop(true)`).
    void run(PollFn poll, void* ctx, EventFn onEvent) {
        using namespace std::chrono_literals;
        bool ok = true;
        std::string reason;
        while (!stop_.load()) {
            const NimFfiMsg* msg = nullptr;
            const int rc = poll(ctx, 250, &msg);
            if (rc == NIMFFI_RET_OK && msg) {
                dispatch(*msg, onEvent);
            } else if (rc == NIMFFI_RET_CLOSED) {
                ok = !msg || msg->ret_code == NIMFFI_RET_OK;
                if (!ok && msg->payload && msg->len > 0)
                    reason.assign(reinterpret_cast<const char*>(msg->payload), msg->len);
                break;
            } else if (rc == NIMFFI_RET_INVALID_CTX) {
                break; // the context ended between two polls
            } else if (rc != NIMFFI_RET_TIMEOUT) {
                std::this_thread::sleep_for(10ms); // BUSY or ERR: try again
            }
        }
        call(matching<ClosedFn>(NIMFFI_MSG_CLOSED, 0), ok, reason);
    }

    std::mutex mtx_;
    std::map<std::uint64_t, Listener> listeners_; // ordered: handlers run in the order they were added
    std::uint64_t nextId_{1};
    std::atomic<bool> stop_{false};
    std::atomic<bool> detached_{false};
};

#endif // NIM_FFI_DISPATCHER_HPP_INCLUDED

// ============================================================
// High-level C++ context class
// ============================================================

class MyTimerCtx {
public:
    /// Creates the FFIContext + MyTimer; async via chronos.
    static Result<std::unique_ptr<MyTimerCtx>> create(const TimerConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = MyTimerCreateCtorReq{config};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<std::unique_ptr<MyTimerCtx>>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            (void)my_timer_create(ffi_req_bytes_.data(), ffi_req_bytes_.size(), cb, ud);
            return 0;
        }, timeout);
        if (ffi_raw_.isErr()) return Result<std::unique_ptr<MyTimerCtx>>::err(ffi_raw_.error());
        auto ffi_addr_ = decodeCborFFI<std::string>(ffi_raw_.value());
        if (ffi_addr_.isErr()) return Result<std::unique_ptr<MyTimerCtx>>::err(ffi_addr_.error());
        const auto& addr_str = ffi_addr_.value();
        std::uint64_t addr = 0;
        const char* addr_begin = addr_str.data();
        const char* addr_end = addr_begin + addr_str.size();
        const auto fc_ = std::from_chars(addr_begin, addr_end, addr);
        if (fc_.ec != std::errc() || fc_.ptr != addr_end) {
            return Result<std::unique_ptr<MyTimerCtx>>::err("FFI create returned non-numeric address: " + addr_str);
        }
        auto ffi_ctx_ = std::unique_ptr<MyTimerCtx>(new MyTimerCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout));
        if (!ffi_ctx_->dispatchThread_.joinable()) {
            return Result<std::unique_ptr<MyTimerCtx>>::err("could not start the event dispatch thread");
        }
        return Result<std::unique_ptr<MyTimerCtx>>::ok(std::move(ffi_ctx_));
    }

    /// Creates the FFIContext + MyTimer; async via chronos.
    static std::future<Result<std::unique_ptr<MyTimerCtx>>> createAsync(const TimerConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        return std::async(std::launch::async, [config, timeout]() { return create(config, timeout); });
    }

    // Special-member policy: this class owns a my_timer context, which in
    // turn owns the library's worker thread(s) and internal state. Moving
    // such an object out from under a caller silently tears that state
    // down and is easy to misuse (e.g. storing in a container that
    // relocates its elements). It also has no clean analogue in the other
    // binding languages we generate. So copies and moves are both
    // deleted; ownership is transferred via MyTimerCtx::create returning a
    // std::unique_ptr<MyTimerCtx>. The destructor still releases the
    // context.
    ~MyTimerCtx() {
        if (ptr_) {
            // Before the dispatch loop stops: the teardown may still emit events, and the
            // poll the dispatch thread is blocked in wakes with NIMFFI_RET_CLOSED.
            my_timer_destroy(ptr_);
            ptr_ = nullptr;
        }
        // A listener may destroy its own context: that runs on the dispatch thread,
        // which cannot join itself and owns its own reference to `dispatcher_`.
        const bool onOwnThread = std::this_thread::get_id() == dispatchThread_.get_id();
        dispatcher_->stop(onOwnThread);
        if (onOwnThread) {
            dispatchThread_.detach();
        } else if (dispatchThread_.joinable()) {
            dispatchThread_.join();
        }
    }

    MyTimerCtx(const MyTimerCtx&) = delete;
    MyTimerCtx& operator=(const MyTimerCtx&) = delete;
    MyTimerCtx(MyTimerCtx&&) = delete;
    MyTimerCtx& operator=(MyTimerCtx&&) = delete;

    // ── Messages from the library ───────────────────────────
    // Everything my_timer sends comes out of my_timer_poll on this context's dispatch thread,
    // which calls the listeners below, in the order they were added:
    //   event "on_echo_fired" (EchoEvent)  -> addOnEchoFiredListener
    //   event "on_job_scheduled" (OnJobScheduledPayload)  -> addOnJobScheduledListener
    //   NIMFFI_MSG_NOT_RESPONDING  -> addNotRespondingListener
    //   NIMFFI_MSG_RESPONDING      -> addRespondingListener
    //   NIMFFI_MSG_CLOSED          -> addClosedListener
    // A listener may call back into this context, add or remove listeners, or
    // destroy the context.
    struct ListenerHandle { std::uint64_t id = 0; };

    /// FNV-1a 64 of "on_echo_fired": the NimFfiMsg.name_id of this event.
    static constexpr std::uint64_t ON_ECHO_FIRED_NAME_ID = 0xcdfdf536356b2a2bULL;
    /// Fired by `myTimerEcho` once the reply is ready.
    ListenerHandle addOnEchoFiredListener(std::function<void(const EchoEvent&)> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_EVENT, ON_ECHO_FIRED_NAME_ID, std::move(handler))};
    }

    /// FNV-1a 64 of "on_job_scheduled": the NimFfiMsg.name_id of this event.
    static constexpr std::uint64_t ON_JOB_SCHEDULED_NAME_ID = 0xd6ac432a40b9a85cULL;
    /// Fired by `myTimerSchedule`. Its two params ride the wire as a synthesised
    /// `OnJobScheduledPayload` envelope, so the foreign side decodes one typed value.
    ListenerHandle addOnJobScheduledListener(std::function<void(const OnJobScheduledPayload&)> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_EVENT, ON_JOB_SCHEDULED_NAME_ID, std::move(handler))};
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
    /// exactly once. `ok` is false when the library gave the context up, and
    /// `reason` then says why. Not called when a listener destroys the context
    /// from the dispatch thread.
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

    /// Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`.
    Result<EchoResponse> echo(const EchoRequest& req) const {
        const auto ffi_req_ = MyTimerEchoReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<EchoResponse>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_echo(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        if (ffi_raw_.isErr()) return Result<EchoResponse>::err(ffi_raw_.error());
        return decodeCborFFI<EchoResponse>(ffi_raw_.value());
    }

    /// Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`.
    std::future<Result<EchoResponse>> echoAsync(const EchoRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return this->echo(req); });
    }

    /// Returns the library's version string.
    Result<std::string> version() const {
        const auto ffi_req_ = MyTimerVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<std::string>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_version(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        if (ffi_raw_.isErr()) return Result<std::string>::err(ffi_raw_.error());
        return decodeCborFFI<std::string>(ffi_raw_.value());
    }

    /// Returns the library's version string.
    std::future<Result<std::string>> versionAsync() const {
        return std::async(std::launch::async, [this]() { return this->version(); });
    }

    Result<ComplexResponse> complex(const ComplexRequest& req) const {
        const auto ffi_req_ = MyTimerComplexReq{req};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<ComplexResponse>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_complex(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        if (ffi_raw_.isErr()) return Result<ComplexResponse>::err(ffi_raw_.error());
        return decodeCborFFI<ComplexResponse>(ffi_raw_.value());
    }

    std::future<Result<ComplexResponse>> complexAsync(const ComplexRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return this->complex(req); });
    }

    /// Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
    Result<ScheduleResult> schedule(const JobSpec& job, const RetryPolicy& retry, const ScheduleConfig& schedule) const {
        const auto ffi_req_ = MyTimerScheduleReq{job, retry, schedule};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<ScheduleResult>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_schedule(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        if (ffi_raw_.isErr()) return Result<ScheduleResult>::err(ffi_raw_.error());
        return decodeCborFFI<ScheduleResult>(ffi_raw_.value());
    }

    /// Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope.
    std::future<Result<ScheduleResult>> scheduleAsync(const JobSpec& job, const RetryPolicy& retry, const ScheduleConfig& schedule) const {
        return std::async(std::launch::async, [this, job, retry, schedule]() { return this->schedule(job, retry, schedule); });
    }

    static Result<std::string> lib_version(std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = MyTimerLibVersionReq{};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Result<std::string>::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_lib_version(cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout);
        if (ffi_raw_.isErr()) return Result<std::string>::err(ffi_raw_.error());
        return decodeCborFFI<std::string>(ffi_raw_.value());
    }

    static std::future<Result<std::string>> lib_versionAsync(std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        return std::async(std::launch::async, [timeout]() { return lib_version(timeout); });
    }

private:
    static void dispatchEvent_(NimFfiDispatcher& dispatcher, const NimFfiMsg& msg) {
        switch (msg.name_id) {
        case ON_ECHO_FIRED_NAME_ID: dispatcher.deliverEvent<EchoEvent>(msg); break;
        case ON_JOB_SCHEDULED_NAME_ID: dispatcher.deliverEvent<OnJobScheduledPayload>(msg); break;
        default: break; // an event from a newer library
        }
    }

    void* ptr_;
    std::chrono::milliseconds timeout_;
    std::shared_ptr<NimFfiDispatcher> dispatcher_;
    std::thread dispatchThread_;
    explicit MyTimerCtx(void* p, std::chrono::milliseconds t)
        : ptr_(p), timeout_(t), dispatcher_(std::make_shared<NimFfiDispatcher>()) {
        dispatchThread_ = NimFfiDispatcher::start(dispatcher_, &my_timer_poll, ptr_, &MyTimerCtx::dispatchEvent_);
    }
};
