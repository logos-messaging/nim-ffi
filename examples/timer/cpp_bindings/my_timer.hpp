#pragma once
#include <string>
#include <cstdint>
#include <chrono>
#include <stdexcept>
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

// ── encode_cbor overloads (primitives + containers) ─────────────────────
// Per-struct encode_cbor / decode_cbor are emitted by cpp.nim next to each
// generated struct. These helpers cover the leaf types and container shapes
// the struct emitters defer into.

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
inline std::vector<std::uint8_t> encodeCborFFI(const T& value) {
    // Start with a generous 4 KiB buffer; double on overflow until it fits.
    std::vector<std::uint8_t> buf(4096);
    while (true) {
        CborEncoder enc;
        cbor_encoder_init(&enc, buf.data(), buf.size(), 0);
        CborError err = encode_cbor(enc, value);
        if (err == CborNoError) {
            const size_t used = cbor_encoder_get_buffer_size(&enc, buf.data());
            buf.resize(used);
            return buf;
        }
        if (err == CborErrorOutOfMemory) {
            const size_t extra = cbor_encoder_get_extra_bytes_needed(&enc);
            buf.resize(buf.size() + (extra > 0 ? extra : buf.size()));
            continue;
        }
        throw std::runtime_error(std::string("FFI CBOR encode failed: ") +
                                 cbor_error_string(err));
    }
}

template<typename T>
inline T decodeCborFFI(const std::vector<std::uint8_t>& bytes) {
    CborParser parser;
    CborValue it;
    CborError err = cbor_parser_init(bytes.data(), bytes.size(), 0, &parser, &it);
    if (err != CborNoError) {
        throw std::runtime_error(std::string("FFI CBOR parse init failed: ") +
                                 cbor_error_string(err));
    }
    T out{};
    err = decode_cbor(it, out);
    if (err != CborNoError) {
        throw std::runtime_error(std::string("FFI CBOR decode failed: ") +
                                 cbor_error_string(err));
    }
    return out;
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
void my_timer_set_event_callback(void* ctx, FFICallback callback, void* user_data);
} // extern "C"

// ============================================================
// Synchronous call helper
// ============================================================

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

inline std::vector<std::uint8_t> ffi_call_(std::function<int(FFICallback, void*)> f,
                                          std::chrono::milliseconds timeout) {
    auto state = std::make_shared<FFICallState_>();
    auto* cb_ref = new std::shared_ptr<FFICallState_>(state);
    const int ret = f(ffi_cb_, cb_ref);
    if (ret == 2) {
        delete cb_ref;
        throw std::runtime_error("RET_MISSING_CALLBACK (internal error)");
    }
    std::unique_lock<std::mutex> lock(state->mtx);
    const bool fired = state->cv.wait_for(lock, timeout, [&]{ return state->done; });
    if (!fired)
        throw std::runtime_error("FFI call timed out after " + std::to_string(timeout.count()) + "ms");
    if (!state->ok)
        throw std::runtime_error(state->err);
    return state->bytes;
}

} // anonymous namespace

// ============================================================
// High-level C++ context class
// ============================================================

class MyTimerCtx {
public:
    static std::unique_ptr<MyTimerCtx> create(const TimerConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = MyTimerCreateCtorReq{config};
        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            (void)my_timer_create(ffi_req_bytes_.data(), ffi_req_bytes_.size(), cb, ud);
            return 0;
        }, timeout);
        const auto addr_str = decodeCborFFI<std::string>(ffi_raw_);
        try {
            const auto addr = std::stoull(addr_str);
            return std::unique_ptr<MyTimerCtx>(new MyTimerCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout));
        } catch (const std::exception&) {
            throw std::runtime_error("FFI create returned non-numeric address: " + addr_str);
        }
    }

    static std::future<std::unique_ptr<MyTimerCtx>> createAsync(const TimerConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
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

    // ── Typed event handlers ────────────────────────────────
    struct Events {
        std::function<void(const std::string&)> on_error;
        std::function<void(const EchoEvent&)> onEchoFired;
    };

    void setEventHandlers(Events handlers) {
        events_ = std::make_unique<Events>(std::move(handlers));
        my_timer_set_event_callback(ptr_, &MyTimerCtx::eventTrampoline, events_.get());
    }

    EchoResponse echo(const EchoRequest& req) const {
        const auto ffi_req_ = MyTimerEchoReq{req};
        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_echo(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFFI<EchoResponse>(ffi_raw_);
    }

    std::future<EchoResponse> echoAsync(const EchoRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return this->echo(req); });
    }

    std::string version() const {
        const auto ffi_req_ = MyTimerVersionReq{};
        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_version(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFFI<std::string>(ffi_raw_);
    }

    std::future<std::string> versionAsync() const {
        return std::async(std::launch::async, [this]() { return this->version(); });
    }

    ComplexResponse complex(const ComplexRequest& req) const {
        const auto ffi_req_ = MyTimerComplexReq{req};
        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_complex(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFFI<ComplexResponse>(ffi_raw_);
    }

    std::future<ComplexResponse> complexAsync(const ComplexRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return this->complex(req); });
    }

    ScheduleResult schedule(const JobSpec& job, const RetryPolicy& retry, const ScheduleConfig& schedule) const {
        const auto ffi_req_ = MyTimerScheduleReq{job, retry, schedule};
        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return my_timer_schedule(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFFI<ScheduleResult>(ffi_raw_);
    }

    std::future<ScheduleResult> scheduleAsync(const JobSpec& job, const RetryPolicy& retry, const ScheduleConfig& schedule) const {
        return std::async(std::launch::async, [this, job, retry, schedule]() { return this->schedule(job, retry, schedule); });
    }

private:
    void* ptr_;
    std::chrono::milliseconds timeout_;
    std::unique_ptr<Events> events_;
    explicit MyTimerCtx(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}
    static void eventTrampoline(int ret, const char* msg, std::size_t len, void* ud) {
        if (!ud) return;
        auto* events = static_cast<Events*>(ud);
        if (ret != 0) {
            if (events->on_error) {
                std::string err(msg ? msg : "", len);
                events->on_error(err);
            }
            return;
        }
        if (!msg || len == 0) return;
        std::vector<std::uint8_t> bytes(reinterpret_cast<const std::uint8_t*>(msg),
                                        reinterpret_cast<const std::uint8_t*>(msg) + len);
        CborParser parser; CborValue it;
        if (cbor_parser_init(bytes.data(), bytes.size(), 0, &parser, &it) != CborNoError) return;
        if (!cbor_value_is_map(&it)) return;
        CborValue evtField;
        if (cbor_value_map_find_value(&it, "eventType", &evtField) != CborNoError) return;
        if (!cbor_value_is_text_string(&evtField)) return;
        std::string evtName; if (decode_cbor(evtField, evtName) != CborNoError) return;
        CborValue payloadField;
        if (cbor_value_map_find_value(&it, "payload", &payloadField) != CborNoError) return;
        if (evtName == "on_echo_fired") {
            if (events->onEchoFired) {
                EchoEvent payload{}; if (decode_cbor(payloadField, payload) == CborNoError) events->onEchoFired(payload);
            }
        }
    }

};
