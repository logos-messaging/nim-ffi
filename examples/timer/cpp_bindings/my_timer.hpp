#pragma once
// Generated bindings require C++20 — the event-listener API uses
// std::span<const std::uint8_t> for the wildcard callback.
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
#include <optional>
#include <type_traits>
#include <cstring>
extern "C" {
#include <tinycbor/cbor.h>
}

// ============================================================
// Result<T> — exception-free error channel
// ============================================================
// The generated bindings never throw: every fallible entry point (create,
// instance methods, and their *Async futures) returns a Result<T>. Callers
// branch on isOk()/isErr() (or the explicit bool conversion) and read
// value()/error(). This mirrors the Nim side's Result[T, string] and keeps
// us off C++23's std::expected. Guarded so two nim-ffi headers can share a
// translation unit.
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
    const T& value() const { return *value_; }
    T& value() { return *value_; }
    const T& operator*() const { return *value_; }
    const T* operator->() const { return &*value_; }
    T&& take() { return std::move(*value_); }
    const std::string& error() const { return error_; }
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
    const std::string& error() const { return error_; }
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

template<typename T>
inline CborError encode_cbor(CborEncoder& e, const std::optional<T>& v) {
    if (!v) return cbor_encode_null(&e);
    return encode_cbor(e, *v);
}

// ── decode_cbor overloads ───────────────────────────────────────────────

inline CborError decode_cbor(CborValue& it, bool& out) {
    if (!cbor_value_is_boolean(&it)) return CborErrorImproperValue;
    CborError err = cbor_value_get_boolean(&it, &out);
    if (err) return err;
    return cbor_value_advance(&it);
}
inline CborError decode_cbor(CborValue& it, int64_t& out) {
    if (!cbor_value_is_integer(&it)) return CborErrorImproperValue;
    CborError err = cbor_value_get_int64_checked(&it, &out);
    if (err) return err;
    return cbor_value_advance(&it);
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
    CborError err = cbor_value_get_uint64(&it, &out);
    if (err) return err;
    return cbor_value_advance(&it);
}
inline CborError decode_cbor(CborValue& it, double& out) {
    if (cbor_value_is_double(&it)) {
        CborError err = cbor_value_get_double(&it, &out);
        if (err) return err;
        return cbor_value_advance(&it);
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
    err = cbor_value_copy_text_string(&it, out.empty() ? nullptr : &out[0], &len, nullptr);
    if (err) return err;
    return cbor_value_advance(&it);
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

struct JobSpec {
    std::string name;
    std::vector<std::string> payload;
    int64_t priority;
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
};
inline CborError encode_cbor(CborEncoder& e, const ScheduleResult& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 4);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "jobId"); if (err) return err;
    err = encode_cbor(m, v.jobId);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "willRunCount"); if (err) return err;
    err = encode_cbor(m, v.willRunCount);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "firstRunAtMs"); if (err) return err;
    err = encode_cbor(m, v.firstRunAtMs);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "effectiveBackoffMs"); if (err) return err;
    err = encode_cbor(m, v.effectiveBackoffMs);              if (err) return err;
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
// C FFI declarations
// ============================================================

extern "C" {
typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);

void* my_timer_create(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);
int my_timer_echo(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_version(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_complex(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_schedule(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_destroy(void* ctx);
uint64_t my_timer_add_event_listener(void* ctx, const char* event_name, FFICallback callback, void* user_data);
int my_timer_remove_event_listener(void* ctx, uint64_t listener_id);
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
    // ffi_call_ heap-allocated a shared_ptr and passed its address as ud;
    // take ownership here so it's freed on every exit path.
    std::unique_ptr<std::shared_ptr<FFICallState_>> handle(
        static_cast<std::shared_ptr<FFICallState_>*>(ud));
    FFICallState_& s = **handle;

    std::lock_guard<std::mutex> lock(s.mtx);
    s.ok = (ret == 0);
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
    if (ret == 2) {
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

template <class T>
inline bool decodeEventPayload(std::span<const std::uint8_t> envelope, T& out) {
    if (envelope.empty()) return false;
    CborParser parser; CborValue it;
    if (cbor_parser_init(envelope.data(), envelope.size(), 0, &parser, &it) != CborNoError)
        return false;
    if (!cbor_value_is_map(&it)) return false;
    CborValue payloadField;
    if (cbor_value_map_find_value(&it, "payload", &payloadField) != CborNoError)
        return false;
    return decode_cbor(payloadField, out) == CborNoError;
}

// ============================================================
// High-level C++ context class
// ============================================================

class MyTimerCtx {
public:
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
        return Result<std::unique_ptr<MyTimerCtx>>::ok(std::unique_ptr<MyTimerCtx>(new MyTimerCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout)));
    }

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
            my_timer_destroy(ptr_);
            ptr_ = nullptr;
        }
    }

    MyTimerCtx(const MyTimerCtx&) = delete;
    MyTimerCtx& operator=(const MyTimerCtx&) = delete;
    MyTimerCtx(MyTimerCtx&&) = delete;
    MyTimerCtx& operator=(MyTimerCtx&&) = delete;

    // ── Event listener API ──────────────────────────────────
    struct ListenerHandle { std::uint64_t id = 0; };

    ListenerHandle addOnEchoFiredListener(std::function<void(const EchoEvent&)> handler) {
        auto owned = std::make_unique<TypedListener<EchoEvent>>(std::move(handler));
        auto* raw = owned.get();
        const auto id = my_timer_add_event_listener(
            ptr_, "on_echo_fired", &MyTimerCtx::typedTrampoline<EchoEvent>, raw);
        if (id == 0) return ListenerHandle{0};
        listeners_.emplace(id, std::move(owned));
        return ListenerHandle{id};
    }

    ListenerHandle addEventListener(std::function<void(int, const std::string&, std::span<const std::uint8_t>)> handler) {
        auto owned = std::make_unique<WildcardListener>(std::move(handler));
        auto* raw = owned.get();
        const auto id = my_timer_add_event_listener(
            ptr_, "", &MyTimerCtx::wildcardTrampoline, raw);
        if (id == 0) return ListenerHandle{0};
        listeners_.emplace(id, std::move(owned));
        return ListenerHandle{id};
    }

    bool removeEventListener(ListenerHandle handle) {
        if (handle.id == 0) return false;
        const auto rc = my_timer_remove_event_listener(ptr_, handle.id);
        listeners_.erase(handle.id);
        return rc == 0;
    }

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

    std::future<Result<EchoResponse>> echoAsync(const EchoRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return this->echo(req); });
    }

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

    std::future<Result<ScheduleResult>> scheduleAsync(const JobSpec& job, const RetryPolicy& retry, const ScheduleConfig& schedule) const {
        return std::async(std::launch::async, [this, job, retry, schedule]() { return this->schedule(job, retry, schedule); });
    }

private:
    struct ListenerBase {
        virtual ~ListenerBase() = default;
    };

    template <class T>
    struct TypedListener : ListenerBase {
        std::function<void(const T&)> fn;
        explicit TypedListener(std::function<void(const T&)> f) : fn(std::move(f)) {}
    };

    struct WildcardListener : ListenerBase {
        std::function<void(int, const std::string&, std::span<const std::uint8_t>)> fn;
        explicit WildcardListener(std::function<void(int, const std::string&, std::span<const std::uint8_t>)> f) : fn(std::move(f)) {}
    };

    template <class T>
    static void typedTrampoline(int ret, const char* msg, std::size_t len, void* ud) {
        if (!ud || ret != 0 || !msg || len == 0) return;
        auto* listener = static_cast<TypedListener<T>*>(ud);
        if (!listener->fn) return;
        CborParser parser; CborValue it;
        if (cbor_parser_init(reinterpret_cast<const std::uint8_t*>(msg), len, 0, &parser, &it) != CborNoError) return;
        if (!cbor_value_is_map(&it)) return;
        CborValue payloadField;
        if (cbor_value_map_find_value(&it, "payload", &payloadField) != CborNoError) return;
        T payload{};
        if (decode_cbor(payloadField, payload) != CborNoError) return;
        listener->fn(payload);
    }

    static void wildcardTrampoline(int ret, const char* msg, std::size_t len, void* ud) {
        if (!ud) return;
        auto* listener = static_cast<WildcardListener*>(ud);
        if (!listener->fn) return;
        std::span<const std::uint8_t> envelope{};
        if (msg && len > 0) {
            envelope = std::span<const std::uint8_t>(reinterpret_cast<const std::uint8_t*>(msg), len);
        }
        std::string eventId;
        if (ret == 0 && !envelope.empty()) {
            CborParser parser; CborValue it;
            if (cbor_parser_init(envelope.data(), envelope.size(), 0, &parser, &it) == CborNoError
                && cbor_value_is_map(&it)) {
                CborValue evtField;
                if (cbor_value_map_find_value(&it, "eventType", &evtField) == CborNoError
                    && cbor_value_is_text_string(&evtField)) {
                    (void)decode_cbor(evtField, eventId);
                }
            }
        }
        listener->fn(ret, eventId, envelope);
    }

    void* ptr_;
    std::chrono::milliseconds timeout_;
    std::unordered_map<std::uint64_t, std::unique_ptr<ListenerBase>> listeners_;
    explicit MyTimerCtx(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}
};
